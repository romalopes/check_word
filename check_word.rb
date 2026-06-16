#!/usr/bin/env ruby
# frozen_string_literal: true

# check_word.rb
# A Ruby script that reads an HTTP(S) URL and checks whether a specific
# word appears in the page. Optionally sends a notification when found.
#
# Usage examples:
#   ruby check_word.rb -u "https://www.mastersofwine.org/mw-exam" -w "2026"
#   ruby check_word.rb -u "https://www.mastersofwine.org/mw-exam" -w "Master" -n desktop
#   ruby check_word.rb -u "https://www.mastersofwine.org/mw-exam" -w "Ruby" -n email \
#     --smtp-host smtp.gmail.com --smtp-port 587 \
#     --smtp-user you@gmail.com --smtp-pass APP_PASSWORD \
#     --email-to you@gmail.com
#   ruby check_word.rb -u https://www.mastersofwine.org/mw-exam" -w "Ruby" -n webhook \
#     --webhook-url "https://hooks.slack.com/services/XXX/YYY/ZZZ"
#   ruby check_word.rb -u "https://www.mastersofwine.org/mw-exam" -w "Master" -n sms \
#     --sms-to 04XXXXXXXX --sms-carrier optus \
#     --smtp-host smtp.gmail.com --smtp-port 587 \
#     --smtp-user you@gmail.com --smtp-pass APP_PASSWORD \
#     --email-from you@gmail.com -i 60
##katarzyna.sobiesiak@gmail.com

#
# Exit codes:
#   0 = word found (and notification sent if requested)
#   2 = word not found
#   1 = error (bad URL, network failure, notification failure, etc.)

require 'net/http'
require 'net/smtp'
require 'uri'
require 'optparse'
require 'json'
require 'time'

class WebsiteWordChecker
  attr_reader :url, :word

  def initialize(url, word, case_sensitive: false, word_boundary: true, show_context: false)
    @url = url
    @word = word
    @case_sensitive = case_sensitive
    @word_boundary = word_boundary
    @show_context = show_context
  end

  # Fetches the content of the given URL.
  def fetch_content
    uri = URI.parse(@url)
    raise "Invalid URL: #{@url}" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    Net::HTTP.start(uri.host, uri.port,
                    use_ssl: uri.scheme == 'https',
                    open_timeout: 10,
                    read_timeout: 10) do |http|
      request = Net::HTTP::Get.new(uri.request_uri, 'User-Agent' => 'Ruby Word Checker/1.0')
      response = http.request(request)
      if response.is_a?(Net::HTTPSuccess)
        response.body
      else
        raise "HTTP request failed: #{response.code} #{response.message}"
      end
    end
  end

  # Builds the regex used to search for the word.
  def build_regex
    flags = @case_sensitive ? 0 : Regexp::IGNORECASE
    pattern = @word_boundary ? "\\b#{Regexp.escape(@word)}\\b" : Regexp.escape(@word)
    Regexp.new(pattern, flags)
  end

  # Removes HTML tags from a string to get cleaner text.
  def strip_html(html)
    amp   = ['&', 'amp'].join
    lt    = ['&', 'lt'].join
    gt    = ['&', 'gt'].join
    quot  = ['&', 'quot'].join
    apos  = ['&', '#39'].join
    nbsp  = ['&', 'nbsp'].join

    html.gsub(/<script.*?<\/script>/im, ' ')
        .gsub(/<style.*?<\/style>/im, ' ')
        .gsub(/<[^>]+>/, ' ')
        .gsub(/#{nbsp}/, ' ')
        .gsub(/#{amp}/, '&')
        .gsub(/#{lt}/, '<')
        .gsub(/#{gt}/, '>')
        .gsub(/#{quot}/, '"')
        .gsub(/#{apos}/, "'")
        .gsub(/\s+/, ' ')
        .strip
  end

  # Checks if the word exists in the website content.
  def word_found?
    html_content = fetch_content
    text_content = strip_html(html_content)
    regex = build_regex

    matches = text_content.scan(regex)
    count = matches.size

    if @show_context && count.positive?
      text_content.to_enum(:scan, regex).each do
        pre_match  = $~.pre_match[-80..-1] || ''
        post_match = $~.post_match[0, 80] || ''
        puts "  Context: ...#{pre_match}#{@word}#{post_match}..."
      end
    end

    { found: count.positive?, count: count }
  end

  def check
    puts "Checking URL: #{@url}"
    puts "Looking for word: \"#{@word}\""
    puts "Case sensitive: #{@case_sensitive}"
    puts 'Fetching content...'

    result = word_found?

    puts ''
    if result[:found]
      puts "✅ FOUND! The word \"#{@word}\" appears #{result[:count]} time(s) on the page."
    else
      puts "❌ NOT FOUND. The word \"#{@word}\" was not found on the page."
    end

    result
  rescue StandardError => e
    warn "Error: #{e.message}"
    { found: false, error: e.message }
  end
end

# --- Notification helpers -------------------------------------------------

module Notifier
  # Sends a desktop notification (macOS). On other OSes it falls back
  # to printing a warning so the user knows the notify step was a no-op.
  def self.desktop(title, body)
    if RUBY_PLATFORM =~ /darwin/
      script = %(display notification "#{escape_for_applescript(body)}" with title "#{escape_for_applescript(title)}")
      system('osascript', '-e', script)
    else
      warn "Desktop notifications are only implemented for macOS; skipping."
    end
  end

  def self.escape_for_applescript(s)
    s.to_s.gsub('\\', '\\\\').gsub('"', '\\"')
  end

  # Sends an email using SMTP with STARTTLS (works with Gmail, etc.).
  def self.email(opts)
    from    = opts.fetch(:from)
    to      = opts.fetch(:to)
    host    = opts.fetch(:host)
    port    = opts.fetch(:port, 587)
    user    = opts[:user]
    pass    = opts[:pass]
    subject = opts[:subject]
    body    = opts[:body]

    message = <<~MESSAGE
      From: #{from}
      To: #{to}
      Subject: #{subject}
      Date: #{Time.now.rfc2822}
      MIME-Version: 1.0
      Content-Type: text/plain; charset=UTF-8

      #{body}
    MESSAGE

    smtp = Net::SMTP.new(host, port)
    smtp.enable_starttls
    smtp.start(host, user, pass, :login) do |s|
      s.send_message(message, from, [to])
    end
  end

  # Sends a JSON POST to a webhook URL (Slack, Discord, custom, etc.).
  def self.webhook(url, payload)
    uri = URI.parse(url)
    raise "Invalid webhook URL: #{url}" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
    req.body = JSON.generate(payload)

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      response = http.request(req)
      unless response.is_a?(Net::HTTPSuccess)
        raise "Webhook failed: #{response.code} #{response.message}"
      end
    end
  end

  # Sends a push notification via ntfy.sh (or any self-hosted ntfy server).
  # Free, no account or API key required. Subscribers receive the message
  # instantly on the ntfy Android/iOS/web app.
  #
  #   Notifier.ntfy(
  #     topic:    'my-topic',
  #     message:  'something happened',
  #     title:    'Optional title',
  #     priority: 'high',        # min|low|default|high|urgent
  #     tags:     'tada,rocket', # comma-separated, ntfy emoji shortcodes
  #     server:   'https://ntfy.sh'  # default
  #   )
  #
  # See: https://docs.ntfy.sh/publish/
  NTFY_PRIORITIES = %w[min low default high urgent].freeze
  DEFAULT_NTFY_SERVER = 'https://ntfy.sh'.freeze

  def self.ntfy(opts)
    topic    = opts.fetch(:topic)
    message  = opts.fetch(:message)
    title    = opts[:title]
    priority = opts[:priority] || 'default'
    tags     = opts[:tags]
    server   = opts[:server]   || DEFAULT_NTFY_SERVER

    raise "ntfy topic is required" if topic.to_s.empty?
    raise "ntfy message is required" if message.to_s.empty?
    unless NTFY_PRIORITIES.include?(priority)
      raise "Invalid ntfy priority '#{priority}'. Use one of: #{NTFY_PRIORITIES.join(', ')}"
    end

    base = URI.parse(server)
    raise "Invalid ntfy server URL: #{server}" unless base.is_a?(URI::HTTP) || base.is_a?(URI::HTTPS)

    target = "#{base.to_s.chomp('/')}/#{URI.encode_www_form_component(topic)}"

    req = Net::HTTP::Post.new(URI.parse(target).request_uri)
    req['Title']    = title.to_s               unless title.to_s.empty?
    req['Priority'] = priority
    req['Tags']     = tags.to_s                unless tags.to_s.empty?
    req['User-Agent'] = 'Ruby Word Checker/1.0 (ntfy)'
    req.body = message.to_s

    Net::HTTP.start(base.host, base.port, use_ssl: base.scheme == 'https', open_timeout: 10, read_timeout: 10) do |http|
      response = http.request(req)
      unless response.is_a?(Net::HTTPSuccess)
        raise "ntfy publish failed: #{response.code} #{response.message}"
      end
    end

    target
  end

  # Writes an entry to a log file.
  def self.log_file(path, entry)
    File.open(path, 'a') do |f|
      f.puts "[#{Time.now.iso8601}] #{entry}"
    end
  end

  # Australian email-to-SMS gateways. Free, no signup, reuses any SMTP
  # credentials. The phone number (digits only, e.g. "0412345678") is
  # appended before the @ to form the destination email address.
  # Sources: each carrier's published support docs. Add new carriers here.
  SMS_GATEWAYS = {
    'telstra'  => 'sms.telstra.com',
    'optus'    => 'sms.optus.com.au',
    'vodafone' => 'voda.com.au',
    'tpg'      => 'sms.tpg.com.au',
    'boost'    => 'boostmobile.com.au',
    'aldi'     => 'sms.aldimobile.com.au',
    'belong'   => 'sms.belong.com.au'
  }.freeze

  # Normalises an Australian mobile number to digits only
  # (e.g. "0412 345 678" -> "0412345678"). Accepts 10-digit "04XXXXXXXX"
  # or 11-digit "614XXXXXXXX" (+61 international form).
  # Returns nil for any other input.
  def self.normalize_au_mobile(number)
    digits = number.to_s.gsub(/\D/, '')
    if digits.length == 11 && digits.start_with?('61')
      "0#{digits[1..]}"
    elsif digits.length == 10 && digits.start_with?('04')
      digits
    end
  end

  # Sends an SMS by emailing a carrier's email-to-SMS gateway.
  # Reuses the same SMTP credentials as the email channel.
  def self.sms_via_gateway(opts)
    number  = opts.fetch(:to)
    carrier = opts.fetch(:carrier).downcase
    gateway_host = SMS_GATEWAYS[carrier]
    raise "Unknown carrier '#{carrier}'. Supported: #{SMS_GATEWAYS.keys.join(', ')}" if gateway_host.nil?

    normalized = normalize_au_mobile(number)
    raise "Invalid Australian mobile number: #{number} (expected 04XXXXXXXX)" if normalized.nil?

    destination = "#{normalized}@#{gateway_host}"
    short_body  = opts[:body].to_s
    short_body  = short_body[0, 140] if short_body.length > 140
    subject     = (opts[:subject] || 'Word found').to_s[0, 60]

    email(
      host: opts[:host],
      port: opts[:port],
      user: opts[:user],
      pass: opts[:pass],
      from: opts[:from],
      to:   destination,
      subject: subject,
      body:   short_body
    )

    destination
  end
end

# --- Command-line parsing -------------------------------------------------

options = {
  case_sensitive: false,
  word_boundary: true,
  show_context: false,
  url: nil,
  word: nil,
  notify: nil,
  smtp_host: nil,
  smtp_port: 587,
  smtp_user: nil,
  smtp_pass: nil,
  email_from: nil,
  email_to: nil,
  webhook_url: nil,
  log_file: nil,
  interval_min: 0,
  max_iterations: 0,
  notify_once: false,
  stop_on_found: false,
  sms_to: nil,
  sms_carrier: 'optus',
  ntfy_topic: nil,
  ntfy_server: Notifier::DEFAULT_NTFY_SERVER,
  ntfy_priority: 'default',
  ntfy_tags: nil
}

OptionParser.new do |opts|
  opts.banner = 'Usage: ruby check_word.rb [options]'

  opts.on('-u', '--url URL', 'The HTTP(S) URL to check (required)') { |u| options[:url] = u }
  opts.on('-w', '--word WORD', 'The word to search for (required)') { |w| options[:word] = w }
  opts.on('-c', '--case-sensitive', 'Perform a case-sensitive search') { options[:case_sensitive] = true }
  opts.on('-p', '--partial', 'Allow partial matches (disable word boundary check)') { options[:word_boundary] = false }
  opts.on('-x', '--context', 'Show context around each match') { options[:show_context] = true }

  opts.on('-n', '--notify CHANNEL', %w[email desktop webhook log sms ntfy],
          'Send a notification when the word is found: email|desktop|webhook|log|sms|ntfy') do |n|
    options[:notify] = n
  end

  opts.on('--ntfy-topic TOPIC', 'ntfy topic name to publish to (for --notify ntfy). Subscribe to this in the ntfy app.') { |t| options[:ntfy_topic] = t }
  opts.on('--ntfy-server URL', "ntfy server base URL (default: #{Notifier::DEFAULT_NTFY_SERVER})") { |s| options[:ntfy_server] = s }
  opts.on('--ntfy-priority LEVEL', Notifier::NTFY_PRIORITIES,
          "ntfy message priority (default: default). One of: #{Notifier::NTFY_PRIORITIES.join(', ')}") { |p| options[:ntfy_priority] = p }
  opts.on('--ntfy-tags TAGS', 'Comma-separated ntfy emoji tags, e.g. "tada,wine_glass" (for --notify ntfy)') { |t| options[:ntfy_tags] = t }

  opts.on('--smtp-host HOST', 'SMTP server host (for --notify email/sms)') { |h| options[:smtp_host] = h }
  opts.on('--smtp-port PORT', Integer, 'SMTP server port (default 587)') { |p| options[:smtp_port] = p }
  opts.on('--smtp-user USER', 'SMTP username') { |u| options[:smtp_user] = u }
  opts.on('--smtp-pass PASS', 'SMTP password') { |p| options[:smtp_pass] = p }
  opts.on('--email-from ADDR', 'From address (for --notify email/sms)') { |f| options[:email_from] = f }
  opts.on('--email-to ADDR',   'To address (for --notify email)')   { |t| options[:email_to] = t }

  opts.on('--sms-to NUMBER',  'Australian mobile number, e.g. 0402522058 (for --notify sms)') { |n| options[:sms_to] = n }
  opts.on('--sms-carrier CARRIER', Notifier::SMS_GATEWAYS.keys,
          "Carrier gateway to use for --notify sms (default: optus). One of: #{Notifier::SMS_GATEWAYS.keys.join(', ')}") do |c|
    options[:sms_carrier] = c
  end

  opts.on('--webhook-url URL', 'Webhook URL to POST to (for --notify webhook)') { |u| options[:webhook_url] = u }
  opts.on('--log-file PATH',   'Log file path (for --notify log)')              { |p| options[:log_file] = p }

  opts.on('-i', '--interval MINUTES', Float,
          'How often (in minutes) to re-check the URL. 0 = run once.') { |i| options[:interval_min] = i }
  opts.on('-N', '--max-iterations N', Integer,
          'Stop after N checks (0 = run forever while polling).') { |n| options[:max_iterations] = n }
  opts.on('--notify-once', 'When polling, send the notification only on the first hit.') { options[:notify_once] = true }
  opts.on('--stop-on-found', 'Stop polling as soon as the word is found at least once.') { options[:stop_on_found] = true }

  opts.on('-h', '--help', 'Display this help') do
    puts opts
    exit
  end
end.parse!

options[:url]  ||= ARGV[0]
options[:word] ||= ARGV[1]

if options[:url].nil? || options[:word].nil?
  print 'Enter the URL: '
  options[:url] ||= gets&.chomp
  print 'Enter the word to search for: '
  options[:word] ||= gets&.chomp
end

if options[:url].nil? || options[:url].empty? || options[:word].nil? || options[:word].empty?
  warn 'Error: Both a URL and a word are required.'
  warn "Usage: ruby check_word.rb -u <URL> -w <WORD>"
  exit 1
end

# --- Send a notification if requested AND the word was found --------------

def send_notification(notify_kind, options, count, url, word)
  return unless notify_kind

  title = "Word found: \"#{word}\""
  body  = "The word \"#{word}\" was found #{count} time(s) on #{url}."

  case notify_kind
  when 'desktop'
    Notifier.desktop(title, body)
    puts '📣 Desktop notification sent.'
  when 'email'
    if [options[:smtp_host], options[:smtp_user], options[:smtp_pass],
        options[:email_from], options[:email_to]].any?(&:nil?)
      raise 'For email notifications you must provide --smtp-host, --smtp-user, --smtp-pass, --email-from, --email-to'
    end
    Notifier.email(
      host: options[:smtp_host],
      port: options[:smtp_port],
      user: options[:smtp_user],
      pass: options[:smtp_pass],
      from: options[:email_from],
      to: options[:email_to],
      subject: title,
      body: body
    )
    puts "📧 Email sent to #{options[:email_to]}."
  when 'webhook'
    if options[:webhook_url].nil?
      raise 'For webhook notifications you must provide --webhook-url'
    end
    Notifier.webhook(options[:webhook_url], text: body)
    puts "🔗 Webhook POSTed to #{options[:webhook_url]}."
  when 'log'
    path = options[:log_file] || 'check_word.log'
    Notifier.log_file(path, body)
    puts "📝 Logged to #{path}."
  when 'sms'
    if [options[:smtp_host], options[:smtp_user], options[:smtp_pass],
        options[:email_from], options[:sms_to]].any?(&:nil?)
      raise 'For SMS notifications you must provide --smtp-host, --smtp-user, --smtp-pass, --email-from, --sms-to'
    end
    destination = Notifier.sms_via_gateway(
      host:    options[:smtp_host],
      port:    options[:smtp_port],
      user:    options[:smtp_user],
      pass:    options[:smtp_pass],
      from:    options[:email_from],
      to:      options[:sms_to],
      carrier: options[:sms_carrier] || 'optus',
      subject: title,
      body:    body
    )
    puts "📱 SMS gateway email sent to #{destination} (via #{options[:sms_carrier] || 'optus'})."
  when 'ntfy'
    if options[:ntfy_topic].to_s.empty?
      raise 'For ntfy notifications you must provide --ntfy-topic'
    end
    target = Notifier.ntfy(
      topic:    options[:ntfy_topic],
      message:  body,
      title:    title,
      priority: options[:ntfy_priority] || 'default',
      tags:     options[:ntfy_tags],
      server:   options[:ntfy_server]   || Notifier::DEFAULT_NTFY_SERVER
    )
    puts "🔔 ntfy notification published to #{target} (priority=#{options[:ntfy_priority] || 'default'})."
  end
end

# --- Run the check (with optional polling) --------------------------------

checker = WebsiteWordChecker.new(
  options[:url],
  options[:word],
  case_sensitive: options[:case_sensitive],
  word_boundary: options[:word_boundary],
  show_context: options[:show_context]
)

interval_min     = options[:interval_min].to_f
max_iterations   = options[:max_iterations].to_i
notify_once      = options[:notify_once]
polling          = interval_min.positive?
ever_found       = false
notified         = false
iteration        = 0

if polling
  if max_iterations.positive?
    puts "🔁 Polling #{options[:url]} every #{interval_min} minute(s); will run for up to #{max_iterations} check(s). Press Ctrl+C to stop."
  else
    puts "🔁 Polling #{options[:url]} every #{interval_min} minute(s). Press Ctrl+C to stop."
  end
end

# Trap Ctrl+C so the polling loop can exit cleanly.
stop_polling = false
Signal.trap('INT') do
  # Can't use puts safely inside a trap on some platforms; use $stderr.
  warn "\n👋 Stopping polling loop..."
  stop_polling = true
end

begin
  loop do
    break if stop_polling

    iteration += 1
    puts ''
    puts "--- Check ##{iteration} at #{Time.now.strftime('%Y-%m-%d %H:%M:%S')} ---"
    result = checker.check

    if result[:found]
      ever_found = true
      if options[:notify] && (!notify_once || !notified)
        begin
          send_notification(options[:notify], options, result[:count], options[:url], options[:word])
          notified = true
        rescue StandardError => e
          warn "Notification failed: #{e.message}"
        end
      end

      # If we only run once (no polling), we're done.
      break unless polling

      # If --stop-on-found was given, stop looping once we have a hit.
      break if options[:stop_on_found]
    end

    break unless polling
    break if max_iterations.positive? && iteration >= max_iterations
    break if stop_polling

    # Sleep in small chunks so Ctrl+C is responsive.
    total_seconds = (interval_min * 60).to_i
    slept = 0
    while slept < total_seconds && !stop_polling
      sleep [total_seconds - slept, 1].min
      slept += 1
    end
  end
rescue StandardError => e
  warn "Error: #{e.message}"
  exit 1
end

exit(ever_found ? 0 : 2)
