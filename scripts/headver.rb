#!/usr/bin/env ruby
require 'fileutils'
require 'date'
require 'open3'

MAJOR = 2

def version
  common, status = Open3.capture2e('git', 'rev-parse', '--git-common-dir')
  raise 'unable to locate git common directory' unless status.success? && !common.strip.empty?
  common = File.expand_path(common.strip)
  dir = File.join(common, 'headver')
  FileUtils.mkdir_p(dir)
  path = File.join(dir, 'counter')
  # Keep the lock separate so replacing the state atomically never changes the locked inode.
  File.open("#{path}.lock", File::RDWR | File::CREAT, 0600) do |lock|
    lock.flock(File::LOCK_EX)
    raw = File.read(path) if File.exist?(path)
    now = Time.now.getlocal('+09:00').strftime('%g%V').to_i
    week = format('%04d', now)
    count = 0
    unless raw.nil?
      m = /\A(\d{4}) (0|[1-9]\d*)\n\z/.match(raw)
      raise 'corrupt counter state' unless m
      saved_week, saved_count = m[1].to_i, m[2].to_i
      begin
        Date.commercial(2000 + saved_week / 100, saved_week % 100, 1)
      rescue ArgumentError
        raise 'corrupt counter state'
      end
      raise 'clock moved backwards' if now < saved_week
      count = saved_week == now ? saved_count + 1 : 0
    end
    File.open("#{path}.next", File::WRONLY | File::CREAT | File::TRUNC, 0600) do |next_state|
      next_state.write("#{week} #{count}\n")
      next_state.flush
      next_state.fsync
    end
    File.rename("#{path}.next", path)
    puts "#{MAJOR}.#{week}.#{count}"
  end
end

begin
  version
rescue => e
  warn "headver: #{e.message}"
  exit 1
end
