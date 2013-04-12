require 'json'
require 'monitor'
require 'set'
require 'pp'
require 'uri'
require 'nokogiri'
require 'httparty'
require_relative 'email_address_validator/email_address_validator'
require_relative 'email_address_validator/regexp.rb'

class Requester
  include HTTParty
end

class NoMorePages < Exception
end

# Ty: https://github.com/michaeledgar/axiom_of_choice/
class Set
  # Picks an arbitrary element from the set and returns it. Use +pop+ to
  # pick and delete simultaneously.
  def pick
    @hash.first.first
  end

  # Picks an arbitrary element from the set and deletes it. Use +pick+ to
  # pick without deletion.
  def pop
    key = pick
    @hash.delete(key)
    key
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
    content.gsub(/\s*@\s/,'@').split(' ').map do |word|
      valid = _validate_email_address word, false
      _validate_email_address word, true if valid
    end.compact.uniq
  end
  def _validate_email_address addr, strict=true
    EmailAddressValidator.check_dns = false
    v1 = EmailAddressValidator.validate(addr)
    if strict
      EmailAddressValidator.check_dns = true
      v2 = EmailAddressValidator.validate(addr)
    else
      v2 = true
    end
    if strict && v1 && !v2 && !addr.split('@')[-1].include?('.')
      # hack on a .com .. wth
      return _validate_email_address "#{addr}.com", true
    end
    return addr if v1 && v2
    return nil
  end
end

# can't put in scraper because it can't be marshal'd
class Scraper

  attr_accessor :root_url

  def initialize root_url
    @root_url = root_url
    @root_url_host = URI.parse(@root_url).host
    @root_url_scheme = URI.parse(@root_url).scheme
    @scrape_queue = []
    @scrape_queue.extend MonitorMixin
    @found_emails = Set.new
    @seen_urls = Set.new
  end

  def scrape
    puts "SCRAPING SITE: #{@root_url}"
    add_url @root_url
    begin
      loop do
        scrape_next_page
        save_to_disk
      end
    rescue NoMorePages
      puts "Exhausted pages"
    end
    @found_emails.to_a
  end

  private

  def save_to_disk
    ScrapeSaver.save_to_disk self
  end

  def next_url
    @scrape_queue.synchronize do
      puts "Queue Length: #{@scrape_queue.length}"
      @scrape_queue.shift rescue nil
    end
  end

  def url_within_root url
    URI.parse(url).host == @root_url_host rescue false
  end

  def add_email_addresses addrs
    addrs.map{ |a| add_email_address a }.compact
  end

  def add_email_address addr
    if @found_emails.add? addr
      addr
    end
  end

  def add_urls links
    links.map{ |l| add_url l }.compact
  end

  def add_url link
    return if link.nil?
    begin
      u = URI.parse(link)
      u.host = @root_url_host unless u.host
      u.scheme = @root_url_scheme unless u.scheme
      link = u.to_s
    rescue
      return nil
    end
    return nil unless url_within_root link
    return nil if skip_url? link
    if @seen_urls.add? link
      puts "Adding url: #{link}"
      @scrape_queue.synchronize do
        @scrape_queue << link
      end
      return link
    else
      return nil
    end
  end
    
  def scrape_next_page
    url = next_url
    raise NoMorePages.new if url.nil?
    return false unless url_within_root url
    return false if skip_url? url
    puts "Scraping next page: #{url}"
    links, email_addresses = self.class.scrape_page url
    puts "Found Addresses: #{email_addresses}" unless email_addresses.empty?
    add_urls links
    add_email_addresses email_addresses
  end

  def skip_url? url
    url.empty? || url.nil?
  end

  class << self

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
      begin
        response = Requester.get(url)
        Nokogiri::HTML(response.body)
      rescue => ex
        puts "Exception getting page: #{ex}"
        return nil
      end
    end

    def scrape_page url
      # TODO catch errors
      puts "scraping page: #{url}"
      page = get_page url
      return [[], []] if page.nil? # nothing to see here
      links = page.links
      if should_scrape_emails? url
        puts "Scraping for email addresses: #{url}"
        email_addresses = page.email_addresses
      else
        email_addresses = []
      end
      [links, email_addresses]
    end

    def should_scrape_emails? url
      true
    end


  end
end


class ProfileScraper < Scraper
  class << self
    def should_scrape_emails? url
      # ends in integer
      pieces = url.split('/').select{|p| !p.nil?}
      last = pieces.last
      ends_in_int = last.to_i.to_s == last
      member_page = url.include?('member.php') || ends_in_int
      excluded = ['list','friends','tags','faqs','blocked',
                  'casting','contests','pic','page']
      off_limits = excluded.select{|e| pieces.include? e}.to_a.length > 0
      member_page && !off_limits
      # one lvl off root
      #off_root = url.gsub(/\/$/,'').count('/') == 3
      #ends_in_int && off_root
    end
  end
end


class ScrapeSaver

  @@to_save = :@scrape_queue, :@found_emails, :@seen_urls, :@root_url
  @@to_save.extend MonitorMixin

  class << self

    def save_path url
      hash = Digest::SHA2.hexdigest url
      path = File.join File.absolute_path('.'), 'data', hash
    end

    def save_to_disk scraper
      @@to_save.synchronize do
        save_path = save_path scraper.root_url
        root_url = scraper.root_url
        to_save = Hash[ 
          @@to_save.map { |attr| 
            [ attr, 
              scraper.instance_eval { 
                v = instance_variable_get attr
                v = v.to_a if v.kind_of? Set
                v
              }
            ] 
          }
        ]
        puts "Saving to disk [#{self}]: #{root_url} #{save_path}"
        File.open(save_path, 'w') do |f|
          JSON.dump(to_save, f)
        end
      end
    end

    def load_from_disk root_url, cls=Scraper
      @@to_save.synchronize do
        path = save_path root_url
        puts "Loading from disk: #{root_url} #{path}"
        return nil unless File.exists? path
        data = nil
        File.open(path) do |f|
          data = JSON.load(f.read)
        end
        obj = cls.new root_url
        data.each do |attr, value|
          obj.instance_eval do
            existing = instance_variable_get attr
            case existing
            when Set, Array
              value.each { |v| existing << v }
            when Hash
              existing.merge! value
            end
          end
        end
        return obj
      end
    end

  end
end



root_url = ARGV.shift rescue nil
proxy_host = ARGV.shift rescue nil
proxy_port = ARGV.shift rescue nil
if proxy_host && proxy_port
  puts "Setting proxy: #{proxy_host} #{proxy_port}"
  Requester.http_proxy proxy_host, proxy_port
end

scraper = ScrapeSaver.load_from_disk root_url, ProfileScraper
scraper ||= ProfileScraper.new root_url

emails = scraper.scrape

puts "--output--\n#{emails.join("\n")}"
