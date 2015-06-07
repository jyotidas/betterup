#!/usr/bin/env ruby

require "open3"
require "whatcd"
require "htmlentities"

# -- edit below --
username = "WHAT_CD_USERNAME"
password = "WHAT_CD_PASSWORD"

flacdir  = "/full/path/to/where/your/FLACs/live"
watchdir = "/full/path/to/your/deluge/or/rtorrent/watchdir"
whatmp3  = "/full/path/to/whatmp3"

bitrates = %w[320 V0 V2]
# -- edit above --

if ARGV.empty? or ARGV.length > 1 or !ARGV.first.start_with? "https"
  abort "Usage: ./betterup.rb \"https://what.cd/torrents.php?torrentid=<torrent_id>\""
end

class Client < WhatCD::Client
  def initialize(username = nil, password = nil)
    @connection = Faraday.new(url: "https://what.cd") do |builder|
      builder.request :multipart
      builder.request :url_encoded
      builder.use :cookie_jar
      builder.adapter Faraday.default_adapter
    end

    unless username.nil? || password.nil?
      authenticate username, password 
    end
  end
  
  def upload(payload)
    unless authenticated?
      raise WhatCD::AuthError
    end

    res = connection.post "/upload.php", payload

    unless res.status == 302 && res.headers["location"] =~ /torrents/
      raise WhatCD::APIError
    end
  end
end

api      = Client.new username, password
authkey  = api.fetch(:index)["authkey"]
torrent  = api.fetch :torrent, id: ARGV.first.strip.split("=").last.to_i
fpath    = HTMLEntities.new.decode(torrent["torrent"]["filePath"]) 
srcdir   = "#{flacdir}/#{fpath}"

unless torrent["torrent"]["encoding"].include? "Lossless"
  abort "Abort! PL does not point to a lossless torrent."
end

if fpath == ""
  abort "Skipping; in violation of r2.3.1, FLACs not enclosed in a folder. Report it!"
end

unless File.directory? srcdir
  abort "FLAC not found in #{flacdir}; nothing to encode."
end

def identity(torrent)
  %w(remasterTitle remasterYear remasterRecordLabel remasterCatalogueNumber media remastered).collect { |attrib| torrent[attrib] }
end

source  = identity(torrent["torrent"])
groupid = torrent["group"]["id"]
group   = api.fetch :torrentgroup, id: groupid

group["torrents"].each do |torrent|
  bitrates.reject! { |bitrate| identity(torrent) == source and torrent["encoding"].include? bitrate }
end

if bitrates.empty?
  abort "#{fpath}: All bitrates already exist; nothing to do."
end

payload = {
  auth: authkey,
  format: "MP3",
  remaster_title: source[0],
  remaster_year: source[1],
  remaster_record_label: source[2],
  remaster_catalogue_number: source[3],
  media: source[4],
  groupid: groupid,
  submit: "true" 
}

if source[5] == true
  payload[:remaster] = "on" 
end

puts "#{fpath}:"

bitrates.each do |bitrate|
  print "Encoding #{bitrate} ... "
  Open3.popen3(*%W(#{whatmp3} --#{bitrate} --output=#{flacdir} #{srcdir})) do |stdin, stdout, stderr, wait_thr|
    while line = stderr.gets
      if line.include? "ERROR while"
        Process.kill("TERM", wait_thr.pid)
        abort "Stopping; something went wrong: #{line}"
      end
    end
    puts "complete."
  end
  fpath =~ /flac/i \
    ? file = fpath.sub(/flac/i, bitrate) + ".torrent" \
    : file = fpath.sub(/$/, " (#{bitrate})") + ".torrent"
  bitrate << " (VBR)" if bitrate.start_with? "V" # nuance to oblige upload.php form
  payload[:file_input] = Faraday::UploadIO.new("#{file}", 'application/x-bittorrent')
  payload[:bitrate] = bitrate
  print "Uploading ... "
  api.upload payload
  puts "done."
  print "Moving #{file} to watchdir ... "
  system *%W(mv #{file} #{watchdir})
  puts "done."
end
