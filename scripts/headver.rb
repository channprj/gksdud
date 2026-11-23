#!/usr/bin/env ruby
require 'fileutils'
require 'time'

MAJOR = 2

def version
  common = `git rev-parse --git-common-dir 2>/dev/null`.strip
  abort 'headver: unable to locate git common directory' unless $?.success? && !common.empty?
  common = File.expand_path(common)
  dir = File.join(common, 'headver')
  FileUtils.mkdir_p(dir)
  path = File.join(dir, 'counter')
  File.open(path, File::RDWR | File::CREAT, 0600) do |f|
    f.flock(File::LOCK_EX)
    raw = f.read
    now = Time.now.getlocal('+09:00').strftime('%g%V').to_i
    week = format('%04d', now)
    count = 0
    unless raw.empty?
      m = /\A(\d{4}) (0|[1-9]\d*)\n\z/.match(raw)
      abort 'headver: corrupt counter state' unless m
      saved_week, saved_count = m[1].to_i, m[2].to_i
      abort 'headver: clock moved backwards' if now < saved_week
      count = saved_week == now ? saved_count + 1 : 0
    end
    f.rewind
    f.truncate(0)
    f.write("#{week} #{count}\n")
    f.flush
    puts "#{MAJOR}.#{week}.#{count}"
  end
end

begin
  version
rescue => e
  warn "headver: #{e.message}"
  exit 1
end
