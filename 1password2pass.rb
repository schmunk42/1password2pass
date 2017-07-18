#!/usr/bin/env ruby

# Copyright (C) 2014 Tobias V. Langhoff <tobias@langhoff.no>. All Rights Reserved.
# This file is licensed under GPLv2+. Please see the following file for more
# information: http://git.zx2c4.com/password-store/tree/COPYING
# 
# 1Password Importer
# 
# Reads files exported from 1Password and imports them into pass. Supports comma
# and tab delimited text files, as well as logins (but not other items) stored
# in the 1Password Interchange File (1PIF) format.
# 
# Supports using the title (default) or URL as pass-name, depending on your
# preferred organization. Also supports importing metadata, adding them with
# `pass insert --multiline`; the username and URL are compatible with
# https://github.com/jvenant/passff.

require "optparse"
require "ostruct"

accepted_formats = [".txt", ".1pif"]

def filter_name(name, pattern, replacement)
  if replacement == false
    return name
  end
  name_filtered = name.gsub(pattern, replacement)
  if name_filtered != name
    puts "WARNING: Changed entry name from '" + name + "' to '" + name_filtered + "'"
    name = name_filtered
  end
  name
end

# Default options
options = OpenStruct.new
options.force = false
options.name = :title
options.notes = true
options.meta = true
options.name_filter_pattern = /[\/\\]/
options.name_filter_replacement = "_"

optparse = OptionParser.new do |opts|
  opts.banner = "Usage: #{opts.program_name}.rb [options] filename"
  opts.on_tail("-h", "--help", "Display this screen") { puts opts; exit }
  opts.on("-f", "--force", "Overwrite existing passwords") do
    options.force = true
  end
  opts.on("-d", "--default [FOLDER]", "Place passwords into FOLDER") do |group|
    options.group = group
  end
  opts.on("-n", "--name [PASS-NAME]", [:title, :url],
          "Select field to use as pass-name: title (default) or URL") do |name|
    options.name = name
  end
  opts.on("-m", "--[no-]meta",
          "Import metadata and insert it below the password") do |meta|
    options.meta = meta
  end
  opts.on("-z", "--[no-]name-filter-replacement REPLACEMENT",
          "Replaces critical symbols (\\,/,...) with REPLACEMENT. Default replacement is a single underscore (_).") do |sym|
    options.name_filter_replacement = sym
  end

  begin 
    opts.parse!
  rescue OptionParser::InvalidOption
    $stderr.puts optparse
    exit
  end
end

# Check for a valid filename
filename = ARGV.pop
unless filename
  abort optparse.to_s
end
unless accepted_formats.include?(File.extname(filename.downcase))
  abort "Supported file types: comma/tab delimited .txt files and .1pif files."
end

passwords = []

# Parse comma or tab delimited text
if File.extname(filename) =~ /.txt/i
  require "csv"

  # Very simple way to guess the delimiter
  delimiter = ""
  File.open(filename) do |file|
    first_line = file.readline
    if first_line =~ /,/
      delimiter = ","
    elsif first_line =~ /\t/
      delimiter = "\t"
    else
      abort "Supported file types: comma/tab delimited .txt files and .1pif files."
    end
  end

  # Import CSV/TSV
  CSV.foreach(filename, {col_sep: delimiter, headers: true, header_converters: :symbol}) do |entry|
    pass = {}
    pass[:name] = "#{(options.group + "/") if options.group}#{filter_name(entry[options.name], options.name_filter_pattern, options.name_filter_replacement)}"
    pass[:title] = entry[:title]
    pass[:password] = entry[:password]
    pass[:login] = entry[:username]
    pass[:url] = entry[:url]
    pass[:notes] = entry[:notes]
    passwords << pass
  end
# Parse 1PIF
elsif File.extname(filename) =~ /.1pif/i
  require "json"

  File.readlines(filename).each do |line|
    next if line =~ /^\*\*\*/
    entry = JSON.parse(line, {symbolize_names: true})

    options.name = :location if options.name == :url

    # Import 1PIF
    next unless entry[:typeName] == "webforms.WebForm"
    pass = {}
    pass[:name] = "#{(options.group + "/") if options.group}#{filter_name(entry[options.name], options.name_filter_pattern, options.name_filter_replacement)}"
    pass[:title] = entry[:title]
    begin
      pass[:password] = entry[:secureContents][:fields].detect do |field|
        field[:name] == "password" or field[:designation] == "password"
      end[:value]
    rescue
      puts "WARNING: No password found in entry " + entry[:title]
      pass[:password] = {}
    end
    begin
      pass[:login] = entry[:secureContents][:fields].detect do |field|
        field[:name] == "username" or field[:designation] == "username"
      end[:value]
    rescue
      puts "WARNING: No username found in entry " + entry[:title]
      pass[:login] = {}
    end
    pass[:url] = entry[:location]
    pass[:notes] = entry[:secureContents][:notesPlain]
    passwords << pass
  end
end

puts "Read #{passwords.length} passwords."

errors = []
# Save the passwords
passwords.each do |pass|
  IO.popen("pass insert #{"-f " if options.force}-m '#{pass[:name]}' > /dev/null", "w") do |io|
    io.puts pass[:password]
    if options.meta
      io.puts "login: #{pass[:login]}" unless pass[:login].to_s.empty?
      io.puts "url: #{pass[:url]}" unless pass[:url].to_s.empty?
      io.puts pass[:notes] unless pass[:notes].to_s.empty?
    end
  end
  if $? == 0
    puts "Imported #{pass[:name]}"
  else
    $stderr.puts "ERROR: Failed to import #{pass[:name]}"
    errors << pass
  end
end

if errors.length > 0
  $stderr.puts "Failed to import #{errors.map {|e| e[:name]}.join ", "}"
  $stderr.puts "Check the errors. Make sure these passwords do not already "\
               "exist. If you're sure you want to overwrite them with the "\
               "new import, try again with --force."
end
