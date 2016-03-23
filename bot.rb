#!/usr/bin/ruby
require 'fileutils'
require 'json'
require 'rubygems'
require 'bundler/setup'
require 'zip'
require 'unirest'

# Sleep this many seconds between polling. This may be 0, but a few seconds are nice if your bot is heavily used.
DELAY = 5
# How many seconds a request may wait for a message before timing out. There' snothing wrong in using
# a large number here. Currently, telegram waits a maximum of 55 seconds, but specifying a larger number doesn't hurt.
LONG_POLLING_TIMEOUT = 600
# Where to save the chats
DIR = "#{File.dirname(__FILE__)}/chats/"
# How many messages to pull. Don't set this larger than the max limit of telegram (currently 100).
POLL_LIMIT = 100

TOKEN = ARGV[0]
if not TOKEN
	puts "No TOKEN set. Get your token by talking to @botfather on Telegram."
	puts "Then call this script like this: `#{$0} <TOKEN>`"
	puts "Exiting."
	exit(1)
end
# Overwrite ZIP files if necessary
Zip.continue_on_exists_proc = true
# The polling request shouldn't time out earlier than the polling timeout, so we add 30 seconds.
Unirest.timeout(LONG_POLLING_TIMEOUT + 30)
FileUtils.mkdir_p(DIR)
offset = 0
# first_run is true at startup.
# as soon as we worked through the queue of messages at startup, it will be set and stay false
# During first_run, we won't sleep between polling and ignore commands.
# (While the bot was down, someone could have sent lots of '/help' waiting for a response.
# We don't want to flood the chat with lots of help messages. ;-) )
first_run = true

# Get the bot's id and username
response = Unirest.get("https://api.telegram.org/bot#{TOKEN}/getMe")
my_id = response.body['result']['id'] rescue nil
my_username = response.body['result']['username'] rescue nil
if not response.body['ok'] or not my_id or not my_username
	puts "Token seems to be invalid. Exiting."
	exit(1)
end
puts "My id is #{my_id}"

loop do
	sleep(DELAY) unless first_run
	print "#{Time.now.strftime('%d.%m.%Y %H:%M:%S')} - Polling with offset #{offset}... "
	response = Unirest.get("https://api.telegram.org/bot#{TOKEN}/getUpdates", :parameters=>{:timeout=>LONG_POLLING_TIMEOUT, :offset=>offset, :limit=>POLL_LIMIT})
	next unless response.body['ok'] && response.body['result']
	
	print "Got #{response.body['result'].count} messages. "
	print "first_run=true" if first_run
	puts
	
	response.body['result'].each do |event|
		(offset = event['update_id'] + 1) if event['update_id'] && event['update_id'] >= offset
		
		if (msg=event['message'])
			chat_id = msg['chat']['id'].to_i
			msg_id = msg['message_id'].to_i
			next unless chat_id && msg_id
			if msg['new_chat_participant'] && msg['new_chat_participant']['id']==my_id
				puts "    New chat #{chat_id}"
				text = "Hello. I'm @#{my_username}. My purpose is to record this chat, so you can later use '/get' to get all messages sent in here for a personal 'backup'. Please join the channel @#{my_username}_news to be stay up-to-date with the bot's development and get infos about new features. You can use the command /delete to make me delete all records of this chat. I'll just sit here and be quiet now. Just ignore me. ;-)"
				Unirest.post("https://api.telegram.org/bot#{TOKEN}/sendMessage", :parameters=>{:chat_id=>chat_id, :disable_notifications=>true, :text=>text})
				next
			elsif msg['left_chat_participant'] && msg['left_chat_participant']['id']==my_id
				puts "    Left chat #{chat_id}"
				next
			end
			# commands will be a message with text '/help', for example
			# In a group with more than one bot, the bot name will be appended.
			# '/help@archival_bot', for example. So we better be careful and snip our
			# username, if necessary.
			text = msg['text'] || ""
			text = text[0..-(my_username.length+2)] if text.end_with?("@#{my_username}")
			case text
			when '/get'
				next if first_run
				puts "    /get"
				file = "/tmp/#{chat_id}.zip"
				Zip::File.open(file, Zip::File::CREATE) do |zip|
					zip.add("#{chat_id}.json", "#{DIR}/#{chat_id}.json")
				end
				Unirest.post("https://api.telegram.org/bot#{TOKEN}/sendDocument", :parameters=>{:document=>File.open(file, 'rb'), :chat_id=>chat_id, :disable_notification=>true})
				next
			when '/delete'
				next if first_run
				text = "You are about to delete my archive of this chat. This cannot be undone. If you are really sure you want to go on, send '@#{my_username} YES I AM SURE'."
				Unirest.post("https://api.telegram.org/bot#{TOKEN}/sendMessage", :parameters=>{:reply_to_message_id=>msg_id, :disable_notification=>true, :chat_id=>chat_id, :text=>text})
			when "@#{my_username} YES I AM SURE"
				next if first_run
				puts "    /delete"
				File.delete("#{DIR}/#{chat_id}.json") rescue nil
				Unirest.post("https://api.telegram.org/bot#{TOKEN}/sendMessage", :parameters=>{:chat_id=>chat_id, :disable_notifications=>true, :text=>"Okay, I've deleted my archive for this chat. Remember to remove me from this chat if you don't want me to start collecting a new archive."})
				next
			when '/help'
				next if first_run
				puts "    /help"
				text = "/get - Request my recordings of this chat as ZIP file.\n"
				text << "/delete - Make me delete my recordings of this chat.\n"
				text << "/help - This help."
				Unirest.post("https://api.telegram.org/bot#{TOKEN}/sendMessage", :parameters=>{:chat_id=>chat_id, :disable_notifications=>true, :text=>text})
			end
			puts "    Message"
			File.open("#{DIR}/#{chat_id}.json", "a") {|f| f.puts(msg.to_json)}
		end
	end
	
	first_run = false if response.body['result'].count < POLL_LIMIT
end
