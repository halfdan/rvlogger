#!/usr/bin/env ruby
require 'rubygems'
require 'sequel'
require 'parseconfig'

if ARGV[0]
  file = ARGV[0]
end

unless File.exists? file
  puts "Usage: ruby init-db.rb /path/to/config.ini"
  exit;
end

puts "Reading config."

config = ParseConfig.new(file)

puts "Creating tables."

DB = Sequel.connect(
  :adapter => config.params['database']['adapter'],
  :host => config.params['database']['host'],
  :user => config.params['database']['user'],
  :password => config.params['database']['pass'],
  :database => config.params['database']['name']
)

puts "- domains"
DB.create_table :vhosts do
  primary_key :id
  String :name, :unique => true, :null => false
end

puts "- traffic"
DB.create_table :traffic do
  primary_key :id
  foreign_key :vhosts_id, :domain
  BigDecimal :bytes
  Date :date
end

class Vhosts < Sequel::Model
  one_to_many :traffic
end

class Traffic < Sequel::Model(:traffic)
  many_to_one :vhosts
end