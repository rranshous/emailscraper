require 'pp'
require 'thread'
require 'uri'
require 'nokogiri'
require 'httparty'
require_relative 'email_address_validator/email_address_validator'
require_relative 'email_address_validator/regexp.rb'

class Queue
  def to_a
    r = []
    begin
      r << deq(true)
    rescue ThreadError
    end
    return r
  end
end

class Nokogiri::HTML::Document
  def links
    # TODO rescue / skip malformed urls
    css('a')
    .map{ |n| n['href'] }
    .select{ |a| !(a.nil? || a.empty?) }
    .map{ |a| URI.parse(a).to_s rescue nil }
    .compact
  end
  def email_addresses
    # TODO rescue / skip non email addresses
    content.gsub(/\s*@\s/,'@').split(' ').select do |word|
      next if word.empty? || word.nil?
      EmailAddressValidator.validate(word)
    end.uniq
  end
end

def scrape_site root_url
  puts "SCRAPING SITE: #{root_url}"
  root_host = URI.parse(root_url).host
  pages = Queue.new
  pages << root_url
  seen = []
  found_emails = Queue.new
  begin
    loop do
      url = pages.deq(true)
      # skip sites outside the root
      unless URI.parse(url).host == root_host
        puts "Skipping URL [#{url}]: outside root"
        next
      end
      links, email_addresses = scrape_page url
      email_addresses.each { |e| found_emails << e }
      links.each do |url| 
        next if url.empty? || url.nil?
        unless seen.include? url
          puts "Enqueing page: #{url}"
          pages << url
          seen << url
        else
          puts "Skipping page: #{url}"
        end
      end
    end
  rescue ThreadError
  end
  found_emails.to_a.uniq
end

def probably_not_html url
  bad_extensions = ['jpeg','jpg','pdf','png','css','js','coffee','gif']
  bad_extensions = bad_extensions.map{|e| [e,e.upcase]}.flatten
  url.downcase.end_with? *bad_extensions
end

def get_page url
  # TODO: catch errors, return nil
  url = "http://#{url}" if URI.parse(url).scheme.nil?
  puts "getting page: #{url}"
  if probably_not_html url
    puts "skipping [#{url}]: probably not html"
    return nil
  end
  response = HTTParty.get(url)
  Nokogiri::HTML(response.body)
end

def scrape_page url
  # TODO catch errors
  puts "scraping page: #{url}"
  page = get_page url
  return [[], []] if page.nil? # nothing to see here
  links, email_addresses = page.links, page.email_addresses
  puts "EMAILS [#{url}]: #{email_addresses}"
  puts "LINKS [#{url}]: #{links}"
  [links, email_addresses]
end

emails = scrape_site ARGV.shift
puts "FOUND:"
pp emails
