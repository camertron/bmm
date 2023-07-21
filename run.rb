#! /usr/bin/env ruby

require "open-uri"
require "rexml"
require "pathname"
require "fileutils"
require "json"
require "aws-sdk-s3"
require "securerandom"
require "erb"

# @TODO: remove
require "debug"

ORIGIN_RSS_FEED_URL = "https://www.omnycontent.com/d/playlist/61af0f78-644a-4500-9792-a89500ea78e5/7cf80bb0-0730-440c-8780-a8ce014a7ff4/2a49b425-5464-47b1-b4be-a8ce014a7ff9/podcast.rss"
BMM_RSS_FEED_URL = "https://bmm.us-ord-1.linodeobjects.com/podcast1.rss"
CLIP_LENGTH_MINUTES = 5

class RssFeed
  def self.template
    @template ||= File.read("feed_template.rss.erb")
  end

  attr_reader :items

  def initialize
    @items = []
  end

  def render
    ERB.new(self.class.template).result(binding)
  end
end

class RssStringItem
  attr_reader :str

  def initialize(str)
    @str = str
  end

  def render
    str
  end
end

class RssFeedItem
  def self.template
    @template ||= File.read("item_template.rss.erb")
  end

  attr_reader :title, :description, :mp3_url, :guid, :pub_date, :duration_sec, :mp3_size_bytes

  def initialize(title:, description:, mp3_url:, guid:, pub_date:, duration_sec:, mp3_size_bytes:)
    @title = title
    @description = description
    @mp3_url = mp3_url
    @guid = guid
    @pub_date = pub_date
    @duration_sec = duration_sec
    @mp3_size_bytes = mp3_size_bytes
  end

  def render
    ERB.new(self.class.template).result(binding)
  end
end

puts "Building offset finder Docker image"

Dir.chdir("offset-finder") do
  system("docker build -t bmm-offset-finder:latest .")
end

FileUtils.mkdir_p("tmp")

origin_rss_doc = REXML::Document.new(URI.open(ORIGIN_RSS_FEED_URL))
bmm_rss_doc = REXML::Document.new(URI.open(BMM_RSS_FEED_URL))
s3_client = Aws::S3::Client.new(region: "us-ord-1", endpoint: "https://us-ord-1.linodeobjects.com")

bmm_items = bmm_rss_doc.get_elements("//rss/channel/item")
first_bmm_item = bmm_items.first
first_bmm_pub_date = Time.parse(first_bmm_item.get_elements("pubDate").first.text).to_date
missing = []

def format_pub_date(time)
  time.strftime("%Y-%m-%d")
end

new_feed = RssFeed.new

bmm_items.each do |bmm_item|
  new_feed.items << RssStringItem.new(bmm_item.to_s)
end

origin_rss_doc.get_elements("//rss/channel/item").each do |origin_item|
  origin_pub_date = Time.parse(origin_item.get_elements("pubDate").first.text).to_date

  if origin_pub_date > first_bmm_pub_date
    missing << origin_item
  end
end

puts "Identified #{missing.size} new episodes to process"

new_rss_items = missing.flat_map do |item_node|
  title = item_node.get_elements("title").first.text
  audio_url = item_node.get_elements("media:content").first["url"]
  pub_date_raw = item_node.get_elements("pubDate").first.text
  pub_date = Time.parse(pub_date_raw)

  puts "Downloading #{title}"

  mp3_outfile_name = "#{format_pub_date(pub_date)}.mp3"
  mp3_outfile_path = File.join("tmp", mp3_outfile_name)
  mp3_outfile = File.open(mp3_outfile_path, 'wb')
  mp3_infile = URI.parse(audio_url).open(
    progress_proc: -> (count_bytes) {
      mb = (count_bytes / (1024 ** 2)).round
      STDOUT.write("\rDownloaded #{mb}mb")
    }
  )

  IO.copy_stream(mp3_infile, mp3_outfile)

  mp3_infile.close
  mp3_outfile.close

  puts

  wav_outfile_name = Pathname(mp3_outfile_name).sub_ext(".wav").to_s
  wav_outfile_path = File.join("tmp", wav_outfile_name)

  puts "Transcoding to wav"
  system("ffmpeg -i #{mp3_outfile_path} -acodec pcm_s16le -ac 1 -ar 16000 #{wav_outfile_path}")

  puts "Identifying offsets"
  offset_data = `docker run --rm -v $(pwd)/tmp:/tmp bmm-offset-finder:latest --file /tmp/#{wav_outfile_name}`
  last_bracket = offset_data.rindex("]")
  offset_data = offset_data[0..last_bracket]
  offsets = JSON.parse(offset_data)
  puts "Found #{offsets.size} offsets at #{offsets.map { |o| o["hr"] }.join(", ")}"

  offsets.sort_by! { |offset| offset["offset"] }

  new_items = offsets.map.with_index do |offset, idx|
    puts "Extracting clip ##{idx + 1}"
    clip_wav_name = "#{format_pub_date(pub_date)}-#{idx + 1}.wav"
    clip_wav_path = "tmp/#{clip_wav_name}"
    system("ffmpeg -ss #{offset["offset"]} -t #{CLIP_LENGTH_MINUTES * 60} -i #{wav_outfile_path} #{clip_wav_path}")

    puts "Transcoding clip ##{idx + 1} to mp3"
    clip_mp3_path = Pathname(clip_wav_path).sub_ext(".mp3").to_s
    system("ffmpeg -i #{clip_wav_path} -vn -ar 44100 -ac 2 -b:a 192k #{clip_mp3_path}")

    File.unlink(clip_wav_path)

    puts "Uploading clip ##{idx + 1} to object storage"
    File.open(clip_mp3_path, "rb") do |file|
      s3_client.put_object(bucket: "bmm", key: File.basename(clip_mp3_path), body: file, acl: "public-read")
    end

    new_item = RssFeedItem.new(
      title: "BMM ##{idx + 1} for #{format_pub_date(pub_date)}",
      description: "BMM ##{idx + 1} for #{format_pub_date(pub_date)}",
      mp3_url: "https://bmm.us-ord-1.linodeobjects.com/#{File.basename(clip_mp3_path)}",
      guid: SecureRandom.uuid,
      pub_date: pub_date_raw,
      duration_sec: CLIP_LENGTH_MINUTES * 60,
      mp3_size_bytes: File.size(clip_mp3_path)
    )

    File.unlink(clip_mp3_path)

    new_item
  end

  File.unlink(wav_outfile_path)
  File.unlink(mp3_outfile_path)

  new_items
end

new_rss_items.reverse_each do |new_rss_item|
  new_feed.items.unshift(new_rss_item)
end

puts "Uploading new RSS document"
s3_client.put_object(bucket: "bmm", key: "podcast1.rss", body: new_feed.render, acl: "public-read")
