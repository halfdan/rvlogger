#!/usr/bin/env ruby
require 'etc'
require 'logger'
require 'fileutils'
require 'rubygems'
require 'sequel'
require 'parseconfig'
require 'getoptlong.rb'
require 'cached_file.rb'

# trap HUP and close all open files
Signal.trap("HUP") do
  @logger.info "Received HUP: Closing all files..."
  CachedFile.close_all
end

def show_version
  puts <<-EOF
RVlogger 1.0 (apache/lighttpd logfile parser)
written by Josh Goebel <dreamer3@gmail.com>
and Fabian Becker <halfdan@xnorfz.de>
based on vlogger by Steve J. Kondik <shade@chemlab.org>

This is free software; see the source for copying conditions.  There is NO
warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
  EOF
  exit
end

def show_help
  puts <<-EOF
Usage: rvlogger [OPTIONS]... [LOGDIR]
Handles a piped logfile from a web server, splitting it into it's
host components, and rotates the files daily.

  -a                    do not autoflush files (default: flush)
  -n                    don't rotate files (default: rotate)
  -k                    known vhosts only
  -f MAXFILES           max number of files to keep open (default: 100)
  -u UID                uid to switch to when running as root
  -g GID                gid to switch to when running as root
  -t TEMPLATE           filename template (as understood by strftime)
                        (default: %Y%m%d-access.log)
  -s SYMLINK            maintain symlink to most recent log file
                        (default: access.log)
  -d CONFIG             use sequel usage tracker
  -x                    ignore www subdomain
  -w SUBDIR             write to SUBDIR in vhost directory                        

  -h                    display this help
  -v                    output version information

When running with -a, performance may improve, but this might confuse some 
log analysis software that expects complete log entries at all times.  

Report bugs and patches to <halfdan@xnorfz.de>.
  EOF
  exit
  #   When running with
  #  -r, the template becomes %Y%m%d-%T-xxx.log.  SIZE is given in bytes.
  #     -r SIZE                     rotate when file reaches SIZE
end 

class VHost

  attr_accessor :hostname
  attr_accessor :file
  
  def initialize(hostname,filename)
    self.hostname=hostname
    begin
      self.file=CachedFile.open filename, "a"      
    rescue
      unless File.exists? File.dirname(filename)
        FileUtils.mkdir_p File.dirname(filename)
      end
      self.file=CachedFile.open filename, "a"
    end
    update_symlink(filename) if RVLogger.symlink
  end
  
  def needs_rotation?
    file.path!=RVLogger.log_filename(hostname)
  end

  def update_symlink filename
    FileUtils.ln_s(
      File.basename(filename),
      File.join(File.dirname(filename), RVLogger.symlink_file),
      :force => true
    )
  end
  
  def write(entry)
    RVLogger.rotate!(self) if needs_rotation?
    file.write entry
  end

end

class RVLogger

  class << self
    attr_accessor :template
    attr_accessor :rotate, :rotate_size
    attr_accessor :symlink
    attr_accessor :symlink_file
    attr_accessor :vhosts
    attr_accessor :subdir
    attr_accessor :ignorewww
    attr_accessor :knownonly
    attr_accessor :uid
    attr_accessor :gid
  end

  @rotate=true
  @template="%Y%m%d-access.log"
  @symlink=false
  @symlink_file="access.log"
  @vhosts={}
  @subdir=""
  @ignorewww=false
  @knownonly=false
  @uid=0
  @gid=0

  def self.rotate!(vhost)
    filename=RVLogger.log_filename(vhost.hostname)
    vhost.file.close 
    vhost.file=CachedFile.open(filename,"a")
    vhost.update_symlink(filename) if RVLogger.symlink
  end

  def self.find(hostname)
    return @vhosts[hostname] if @vhosts[hostname]
    # puts "creating new vhost for #{hostname}"
    @vhosts[hostname]=VHost.new(hostname, log_filename(hostname))
  end

  
  def self.log_filename(vhost)
    return File.join(vhost, @subdir, @template) unless @rotate
    File.join(vhost, @subdir, Time.now.strftime(@template))
  end
  
end

# handle arguments
parser = GetoptLong.new
parser.set_options(
  ["--user","-u", GetoptLong::REQUIRED_ARGUMENT],
  ["--group","-g", GetoptLong::REQUIRED_ARGUMENT],
  ["--maxfiles","-f", GetoptLong::REQUIRED_ARGUMENT],
  ["--knownonly", "-k", GetoptLong::NO_ARGUMENT],
  ["--symlink","-s", GetoptLong::OPTIONAL_ARGUMENT],
  ["--noflush","-a", GetoptLong::NO_ARGUMENT],
  ["--norotate","-n", GetoptLong::NO_ARGUMENT],
  ["--size","-r", GetoptLong::REQUIRED_ARGUMENT],
  ["--template","-t", GetoptLong::REQUIRED_ARGUMENT],
  ["--ignorewww","-x", GetoptLong::NO_ARGUMENT],
  ["--subdir","-w", GetoptLong::REQUIRED_ARGUMENT],
  ["--help","-h", GetoptLong::NO_ARGUMENT],
  ["--version","-v", GetoptLong::NO_ARGUMENT]
)

parser.each_option do |name, arg|
  opt=name.gsub(/^--/,"").to_sym
  case opt
  when :version
    show_version
  when :help
    show_help
  when :user
    RVLogger.uid=Etc.getpwnam(arg).uid rescue (puts "User #{arg} not found."; exit)
  when :group
    RVLogger.gid=Etc.getgrnam(arg).gid rescue (puts "Group #{arg} not found."; exit)
  when :knownonly
    RVLogger.knownonly=true
  when :template
    Time.now.strftime(arg) # catch any errors early
    RVLogger.template=arg
  when :norotate
    RVLogger.rotate=false
    RVLogger.template="access.log"
  when :symlink
    RVLogger.symlink=true
    RVLogger.symlink_file=arg unless arg.empty?
  when :size
    RVLogger.rotate_size=arg.to_i
  when :maxfiles
    CachedFile.max_file_handles=arg.to_i
  when :noflush
    CachedFile.flush=false
  when :subdir
    RVLogger.subdir=arg
  when :ignorewww
    RVLogger.ignorewww=true
  end
end

# show help if we're not passed a path
show_help if ARGV[0].nil?
# chroot to log dir if we were passed a path
if (File.exists? ARGV[0])
  begin
    Dir.chdir(ARGV[0])
    Dir.chroot('.')
  rescue
    puts $!
    exit 1
  end
else
  puts "Log path does not exist: #{ARGV[0]}."; exit
end

# Change gid if requested
if RVLogger.gid > 0
  unless Process::GID.change_privilege(RVLogger.gid) == RVLogger.gid
      puts "No permission to become group #{RVLogger.gid}."; exit
  end
end

# Change uid if requested
if RVLogger.uid > 0
  unless Process::UID.change_privilege(RVLogger.uid) == RVLogger.uid
      puts("No permission to become #{RVLogger.uid}."); exit
  end
end

#while line = STDIN.gets do
STDIN.each_line do |line|
  # Get the first token from the log record; it's the identity
  # of the virtual host to which the record applies.
  vhost=line.split(/\s/).first
  next if vhost.nil?

  # Normalize the virtual host name to all lowercase.
  vhost.downcase!
    
  # if the vhost contains a "/" or "\", it is illegal
  vhost="default" if vhost =~ /\/|\\/

  # Remove www. from hostname if -x was given.
  vhost.gsub!(/^www\./,"") if RVLogger.ignorewww

  # Remove port from vhost name
  vhost.gsub!(/:\d+$/,"")     # no ports

  # Allow only known vhosts
  if RVLogger.knownonly    
    vhost="default" unless File.exist? vhost
  end

  # Strip off the first token (which may be null in the
  # case of the default server)
  line.gsub!(/^\S*\s+/,"")

  begin
    RVLogger.find(vhost).write line
    #    rescue
    #      puts "Couldn't write to log: #{RVLogger.log_filename(vhost)}"
  end
end

CachedFile.close_all
