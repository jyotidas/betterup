#!/usr/bin/env ruby

require "open3"
require "whatcd"
require "htmlentities"

# -- edit below --
username = "WHAT_CD_USERNAME"
password = "WHAT_CD_PASSWORD"

flacdir  = "/full/path/to/where/your/FLACs/live"
outdir   = "/full/path/to/where/you/want/your/transcodes/to/go"
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
  
  def authenticate(username, password)
    body = { :username => username, :password => password, :keeplogged => 1 }
    res  = connection.post "/login.php", body

    unless res["set-cookie"] && res["location"] == "index.php"
      raise WhatCD::AuthError
    end
    File.write('cookie.txt', res["set-cookie"].match('session.*').to_s)
    @authenticated = true
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

if File.exist? "cookie.txt" 
  api = Client.new
  api.set_cookie File.read("cookie.txt")
else
  api = Client.new username, password
end  

authkey  = api.fetch(:index)["authkey"]
torrent  = api.fetch :torrent, id: ARGV.first.strip.split("=").last.to_i
fpath    = HTMLEntities.new.decode(torrent["torrent"]["filePath"]) 
srcdir   = "#{flacdir}/#{fpath}"

if torrent["torrent"]["encoding"] != "Lossless"
  abort "Abort! PL does not point to a 16bit FLAC."
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
  Open3.popen3(*%W(#{whatmp3} --#{bitrate} --output=#{outdir} #{srcdir})) do |stdin, stdout, stderr, wait_thr|
    begin
      stdout.each { |line| print line }
    rescue Errno::EIO
      puts "Errno:EIO error, but this probably just means " +
           "that the process has finished giving output."
    end
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
  print "Moving #{file} to #{watchdir} ... "
  system *%W(mv #{file} #{watchdir})
  puts "done."
end
