#!/usr/local/bin/ruby
require 'etc'
require 'logger'
require 'fileutils'
require 'rubygems'
require 'sequel'
require 'parseconfig'
require 'apachelogregex'
require 'getoptlong.rb'
require 'yaml'
require File.expand_path("../cached_file.rb", __FILE__)

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
  -e                    errorlog mode
  -n                    don't rotate files (default: rotate)
  -k                    known vhosts only (default: false)
  -f MAXFILES           max number of files to keep open (default: 100)
  -u UID                uid to switch to when running as root
  -g GID                gid to switch to when running as root
  -t TEMPLATE           filename template (as understood by strftime)
                        (default: %Y%m%d-access.log)
  -s SYMLINK            maintain symlink to most recent log file
                        (default: current.log)
  -c CONFIG             use CONFIG file
  -d                    use database recording (default: false)
  -x                    ignore www subdomain (default: false)
  -w SUBDIR             write to SUBDIR in vhost directory
                        (default: empty)

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
  attr_accessor :changed
  attr_accessor :config
  attr_accessor :id 
  @changed=false
 
  def initialize(config,hostname,id=0)
    # Initially there is no change
    @changed=false
    @hostname=hostname
    @config=config
    @id=id
    @traffic=0

    filename = log_filename(hostname)
    begin
      @file=CachedFile.open filename, "a"      
    rescue
      # Create directory if neccessary
      unless File.exists? File.dirname(filename)
        FileUtils.mkdir_p File.dirname(filename)
      end
      # Open file
      @file=CachedFile.open filename, "a"
    end
    update_symlink(filename) if config.params['general']['symlink']
  end 

  def write(line)
    # Rotate if neccessary
    rotate! if needs_rotation?
    # Write entry
    file.write line
    # A change has occured
    self.changed=true
    # Update traffic
    if config.params['general']['use_db']
      parser = ApacheLogRegex.new(config.params['general']['logfile_format'])
      res = parser.parse(line)
      @traffic += 1024
    end
  end
  
  def update_db dbconnection
    traffic = dbconnection[:traffic]
    today = traffic.filter(:vhosts_id => @id, :date => Date.today.to_s)
    if today.count > 0
      bytes = today.first[:bytes]
      bytes = bytes.to_i + @traffic
      today.update(:bytes => bytes)
    else
      traffic.insert(
        :vhosts_id => @id,
        :date => Date.today.to_s,
        :bytes => @traffic
      )
    end
    # Reset traffic
    @traffic=0
  end
  
  private

  def needs_rotation?
    file.path!=log_filename(hostname)
  end

  def rotate!
    filename=log_filename(hostname)
    file.close
    file=CachedFile.open(filename,"a")
    update_symlink(filename) if config.params['general']['symlink']
  end

  def log_filename(hostname)
    # Only parse template if rotation is true
    return File.join(
      config.params['general']['logpath'],
      hostname,
      config.params['general']['subdir'],
      config.params['general']['template']
    ) unless config.params['general']['rotate']

    File.join(
      config.params['general']['logpath'],
      hostname,
      config.params['general']['subdir'],
      Time.now.strftime(config.params['general']['template'])
    )
  end

  def update_symlink filename
    FileUtils.ln_s(
      File.basename(filename),
      File.join(File.dirname(filename), config.params['general']['symlink_file']),
      :force => true
    )
  end
end

class RVLogger

  def initialize(config, database=nil)
    @config=config
    @dbconn=database unless database.nil?
    @vhosts={}
  end  

  def find(hostname)
    return @vhosts[hostname] if @vhosts[hostname]

    # Add vhost to DB if active
    if @config.params['general']['use_db']
      domains = @dbconn[:vhosts].filter(:name => hostname)
      unless domains.count > 0
        domains.insert(:name => hostname)
      end
      row = domains[:name=>hostname]
      id = row[:id]
      @vhosts[hostname]=VHost.new(@config, hostname, id)
    else
      @vhosts[hostname]=VHost.new(@config, hostname)
    end
  end

  def update_db
    @vhosts.each do |hostname,vhost|
      if vhost.changed
        # Update DB
        vhost.update_db @dbconn
        vhost.changed=false
      end
    end
  end  
end

# Instantiate ParseConfig
config = ParseConfig.new

# Set default config
config.add("general", {
    :rotate => true,
    :known_hosts_only => false,
    :max_files => 100,
    :uid => 0,
    :gid => 0,
    :template => '%Y%m%d-access.log',
    :symlink => true,
    :symlink_name => 'current.log',
    :use_db => false,
    :ignore_www => false,
    :subdir => '',
    :logfile_format => '%h %l %u %t "%r" %>s %O "%{Referer}i" "%{User-Agent}i"'
  }
)

# As default we use sqlite
config.add("database", {
    :adapter => 'sqlite',
    :host => '',
    :user => '',
    :password => '',
    :name => 'rvlogger.db',
    :dump => 30
  }
)


# handle arguments
parser = GetoptLong.new
parser.set_options(
  ["--user","-u", GetoptLong::REQUIRED_ARGUMENT],
  ["--group","-g", GetoptLong::REQUIRED_ARGUMENT],
  ["--max-files","-f", GetoptLong::REQUIRED_ARGUMENT],
  ["--known-hosts-only", "-k", GetoptLong::NO_ARGUMENT],
  ["--symlink","-s", GetoptLong::OPTIONAL_ARGUMENT],
  ["--no-flush","-a", GetoptLong::NO_ARGUMENT],
  ["--no-rotate","-n", GetoptLong::NO_ARGUMENT],
  ["--size","-r", GetoptLong::REQUIRED_ARGUMENT],
  ["--template","-t", GetoptLong::REQUIRED_ARGUMENT],
  ["--ignore-www","-x", GetoptLong::NO_ARGUMENT],
  ["--subdir","-w", GetoptLong::REQUIRED_ARGUMENT],
  ["--help","-h", GetoptLong::NO_ARGUMENT],
  ["--config", "-c", GetoptLong::REQUIRED_ARGUMENT],
  ["--use-db", "-d", GetoptLong::NO_ARGUMENT],
  ["--version","-v", GetoptLong::NO_ARGUMENT]
)

parser.each_option do |name, arg|
  opt=name.gsub(/^--/,"").gsub(/-/,'_').to_sym
  case opt
  when :version
    show_version
  when :help
    show_help
  when :user
    uid = Etc.getpwnam(arg).uid rescue (puts "User #{arg} not found."; exit)
    config.add_to_group("general", "uid", uid)
  when :group
    gid = Etc.getgrnam(arg).gid rescue (puts "Group #{arg} not found."; exit)
    config.add_to_group("general", "gid", gid)
  when :known_hosts_only
    config.add_to_group("general", "known_hosts_only", true)
  when :template
    Time.now.strftime(arg) # catch any errors early
    config.add_to_group("general", "template", arg)
  when :no_rotate
    config.add_to_group("general", "template", "access.log")
    config.add_to_group("general", "rotate", false)
  when :symlink
    config.add_to_group("general", "symlink", true)
    if arg.empty?
      config.add_to_group("general", "symlink_file", "current.log")
    else
      config.add_to_group("general", "symlink_file", arg)
    end
  when :size
    config.add_to_group('general', 'rotate_size', arg.to_i)
  when :max_files
    #config.add_to_group('general', 'max_file_handles', arg.to_i)
    CachedFile.max_file_handles=arg.to_i
  when :no_flush
    CachedFile.flush=false
  when :subdir
    config.add_to_group('general', 'subdir', arg)
  when :ignore_www
    config.add_to_group('general', 'ignore_www', true)
  when :config
    if File.exists? arg
      config.config_file=arg
    end
  when :use_db
    config.add_to_group('general', 'use_db', true)
  end
end

# Import config if set
if config.config_file
  config.import_config
end

# show help if we're not passed a path
show_help if ARGV[0].nil?
# chroot to log dir if we were passed a path
if (File.exists? ARGV[0])
  begin
    config.add_to_group('general', 'logpath', ARGV[0])
#    Dir.chdir(ARGV[0])
#    Dir.chroot('.')
  rescue
    puts $!
    exit 1
  end
else
  puts "Log path does not exist: #{ARGV[0]}."; exit
end

# Change gid if requested
gid = config.params['general']['gid']

if gid.to_i > 0
  unless Process::GID.change_privilege(gid) == gid
    puts "No permission to become group #{gid}."; exit
  end
end

# Change uid if requested
uid = config.params['general']['uid']

if uid.to_i > 0
  unless Process::UID.change_privilege(uid) == uid
    puts("No permission to become #{uid}."); exit
  end
end

# Connect to db if use_db => true
begin
  DB = Sequel.connect(
    :adapter => config.params['database']['adapter'],
    :host => config.params['database']['host'],
    :user => config.params['database']['user'],
    :password => config.params['database']['pass'],
    :database => config.params['database']['name']
  ) if config.params['general']['use_db']
rescue
  puts "Could not connect to database!"
  puts $!
  exit;
end

# Instantiate RVLogger
if config.params['general']['use_db']
  rvlogger = RVLogger.new(config, DB)
else
  rvlogger = RVLogger.new(config)
end

time = Time.now

# Begin main loop
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
  vhost.gsub!(/^www\./,"") if config.params['general']['ignore_www'] == "true"

  # Remove port from vhost name
  vhost.gsub!(/:\d+$/,"")     # no ports

  # Allow only known vhosts
  if config.params['general']['known_hosts_only'] == "true"
    vhost="default" unless File.exist? vhost
  end

  # Strip off the first token (which may be null in the
  # case of the default server)
  line.gsub!(/^\S*\s+/,"")

  begin
    rvlogger.find(vhost).write line
    #    rescue
    #      puts "Couldn't write to log: #{RVLogger.log_filename(vhost)}"
  end

  # Only continue if we use_db
  next unless config.params['general']['use_db']

  # Is it time to update the database?
  if Time.now > time + config.params['database']['dump'].to_i
    rvlogger.update_db
  end
end

rvlogger.update_db
CachedFile.close_all
