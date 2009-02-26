# Inspired by rabbitmq.rake the Redbox project at http://github.com/rick/redbox/tree/master
require 'fileutils'

class RedisRunner
  
  def self.basedir
    basedir = File.expand_path(File.dirname(__FILE__) + "/../") # ick
  end
  
  def self.redisdir
    "#{basedir}/redis"
  end

  def self.dtach_socket
    "#{basedir}/tmp/redis.dtach"
  end

  # Just check for existance of dtach socket
  def self.running?
    File.exists? dtach_socket
  end
  
  def self.start
    exec "dtach -A #{dtach_socket} #{redisdir}/redis-server"
  end
  
  def self.attach
    exec "dtach -a #{dtach_socket}"
  end
  
  def self.stop
    # ?
  end

end

namespace :redis do
  
  desc "Start Redis"
  task :start => [:download, :make] do
    RedisRunner.start
  end

  desc "Attach to RabbitMQ dtach socket"
  task :attach do
    RedisRunner.attach
  end
  
  task :make do
    sh "cd #{RedisRunner.redisdir} && make"
  end  

  desc "Download package"
  task :download do
    unless File.exists?(RedisRunner.redisdir)
        system "curl http://redis.googlecode.com/files/redis-beta-1.tar.gz -O &&
                tar xvzf redis-beta-1.tar.gz"
    end  
  end
    

end