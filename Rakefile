require 'rubygems'
require 'rubygems/package_task'
require 'rake/testtask'

ENV["REDIS_BRANCH"] ||= "unstable"

$:.unshift File.join(File.dirname(__FILE__), 'lib')
require 'redis/version'

REDIS_DIR = File.expand_path(File.join("..", "test"), __FILE__)
REDIS_CNF = File.join(REDIS_DIR, "test.conf")
REDIS_PID = File.join(REDIS_DIR, "db", "redis.pid")
BINARY = "tmp/redis-#{ENV["REDIS_BRANCH"]}/src/redis-server"

task :default => :run

desc "Run tests and manage server start/stop"
task :run => [:start, :test, :stop]

desc "Start the Redis server"
task :start => BINARY do
  sh "#{BINARY} --version"

  redis_running = \
  begin
    File.exists?(REDIS_PID) && Process.kill(0, File.read(REDIS_PID).to_i)
  rescue Errno::ESRCH
    FileUtils.rm REDIS_PID
    false
  end

  unless redis_running
    unless system("#{BINARY} #{REDIS_CNF}")
      abort "could not start redis-server"
    end
  end
end

desc "Stop the Redis server"
task :stop do
  if File.exists?(REDIS_PID)
    Process.kill "INT", File.read(REDIS_PID).to_i
    FileUtils.rm REDIS_PID
  end
end

file BINARY do
  branch = ENV.fetch("REDIS_BRANCH")

  sh <<-SH
  mkdir -p tmp;
  cd tmp;
  wget https://github.com/antirez/redis/archive/#{branch}.tar.gz -O #{branch}.tar.gz;
  tar xf #{branch}.tar.gz;
  cd redis-#{branch};
  make
  SH
end

Rake::TestTask.new do |t|
  t.options = "-v"
  t.test_files = FileList["test/*_test.rb"]
end

task :doc => ["doc:generate", "doc:prepare"]

namespace :doc do
  task :generate do
    require "shellwords"

    `rm -rf doc`

    current_branch = `git branch`[/^\* (.*)$/, 1]

    begin
      tags = `git tag -l`.split("\n").sort.reverse

      tags.each do |tag|
        `git checkout -q #{tag} 2>/dev/null`

        unless $?.success?
          $stderr.puts "Need a clean working copy. Please git-stash away."
          exit 1
        end

        puts tag

        `mkdir -p doc/#{tag}`

        files = `git ls-tree -r HEAD lib`.split("\n").map do |line|
          line[/\t(.*)$/, 1]
        end

        opts = [
          "--title", "A Ruby client for Redis",
          "--output", "doc/#{tag}",
          "--no-cache",
          "--no-save",
          "-q",
          *files
        ]

        `yardoc #{Shellwords.shelljoin opts}`
      end
    ensure
      `git checkout -q #{current_branch}`
    end
  end

  task :prepare do
    versions = `git tag -l`.split("\n").grep(/^v/).sort
    latest_version = versions.last

    File.open("doc/.htaccess", "w") do |file|
      file.puts "RedirectMatch 302 ^/?$ /#{latest_version}"
    end

    File.open("doc/robots.txt", "w") do |file|
      file.puts "User-Agent: *"

      (versions - [latest_version]).each do |version|
        file.puts "Disallow: /#{version}"
      end
    end

    google_analytics = <<-EOS
    <script type="text/javascript">

      var _gaq = _gaq || [];
      _gaq.push(['_setAccount', 'UA-11356145-2']);
      _gaq.push(['_trackPageview']);

      (function() {
        var ga = document.createElement('script'); ga.type = 'text/javascript'; ga.async = true;
        ga.src = ('https:' == document.location.protocol ? 'https://ssl' : 'http://www') + '.google-analytics.com/ga.js';
        var s = document.getElementsByTagName('script')[0]; s.parentNode.insertBefore(ga, s);
      })();

    </script>
    EOS

    Dir["doc/**/*.html"].each do |path|
      lines = IO.readlines(path)

      File.open(path, "w") do |file|
        lines.each do |line|
          if line.include?("</head>")
            file.write(google_analytics)
          end

          file.write(line)
        end
      end
    end
  end

  task :deploy do
    system "rsync --del -avz doc/ redis-rb.keyvalue.org:deploys/redis-rb.keyvalue.org/"
  end
end

class Source

  MATCHER = "(?:\\s{%d}#[^\\n]*\\n)*^\\s{%d}def ([a-z_?]+)(?:\(.*?\))?\\n.*?^\\s{%d}end\\n\\n"

  def initialize(data, options = {})
    @doc = parse(File.read(data), options)
  end

  def methods
    @doc.select do |d|
      d.is_a?(Method)
    end.map do |d|
      d.name
    end
  end

  def move(a, b)
    ao = @doc.find { |m| m.is_a?(Method) && m.name == a }
    bo = @doc.find { |m| m.is_a?(Method) && m.name == b }
    ai = @doc.index(ao)
    bi = @doc.index(bo)

    @doc.delete_at(ai)
    @doc.insert(bi, ao)

    nil
  end

  def to_s
    @doc.join
  end

  protected

  def parse(data, options = {})
    re = Regexp.new(MATCHER % ([options[:indent]] * 3), Regexp::MULTILINE)
    tail = data.dup
    doc = []

    while match = re.match(tail)
      doc << match.pre_match
      doc << Method.new(match)
      tail = match.post_match
    end

    doc << tail if tail
    doc
  end

  class Method

    def initialize(match)
      @match = match
    end

    def name
      @match[1]
    end

    def to_s
      @match[0]
    end
  end
end

namespace :commands do
  def redis_commands
    $redis_commands ||= doc.keys.map do |key|
      key.split(" ").first.downcase
    end.uniq
  end

  def doc
    $doc ||= begin
      require "open-uri"
      require "json"

      JSON.parse(open("https://github.com/antirez/redis-doc/raw/master/commands.json").read)
    end
  end

  task :order do
    require "json"

    reference = if File.exist?(".order")
                  JSON.parse(File.read(".order"))
                else
                  {}
                end

    buckets = {}
    doc.each do |k, v|
      buckets[v["group"]] ||= []
      buckets[v["group"]] << k.split.first.downcase
      buckets[v["group"]].uniq!
    end

    result = (reference.keys + (buckets.keys - reference.keys)).map do |g|
      [g, reference[g] + (buckets[g] - reference[g])]
    end

    File.open(".order", "w") do |f|
      f.write(JSON.pretty_generate(Hash[result]))
    end
  end

  def reorder(file, options = {})
    require "json"
    require "set"

    STDERR.puts "reordering #{file}..."

    reference = if File.exist?(".order")
                  JSON.parse(File.read(".order"))
                else
                  {}
                end

    dst = Source.new(file, options)

    src_methods = reference.map { |k, v| v }.flatten
    dst_methods = dst.methods

    src_set = Set.new(src_methods)
    dst_set = Set.new(dst_methods)

    intersection = src_set & dst_set
    intersection.delete("initialize")

    loop do
      src_methods = reference.map { |k, v| v }.flatten
      dst_methods = dst.methods

      src_methods = src_methods.select do |m|
        intersection.include?(m)
      end

      dst_methods = dst_methods.select do |m|
        intersection.include?(m)
      end

      if src_methods == dst_methods
        break
      end

      rv = yield(src_methods, dst_methods, dst)
      break if rv == false
    end

    File.open(file, "w") do |f|
      f.write(dst.to_s)
    end
  end

  task :reorder do
    blk = lambda do |src_methods, dst_methods, dst|
      src_methods.zip(dst_methods).each do |a, b|
        if a != b
          dst.move(a, b)
          break
        end
      end
    end

    reorder "lib/redis.rb", :indent => 2, &blk
    reorder "lib/redis/distributed.rb", :indent => 4, &blk
  end

  def missing(file, options = {})
    src = Source.new(file, options)

    defined_methods = src.methods.map(&:downcase)
    required_methods = redis_commands.map(&:downcase)

    STDOUT.puts "missing in #{file}:"
    STDOUT.puts (required_methods - defined_methods).inspect
  end

  task :missing do
    missing "lib/redis.rb", :indent => 2
    missing "lib/redis/distributed.rb", :indent => 4
  end

  def document(file)
    source = File.read(file)

    doc.each do |name, command|
      source.sub!(/(?:^ *# .*\n)*(^ *#\n(^ *# .+?\n)*)*^( *)def #{name.downcase}(\(|$)/) do
        extra_comments, indent, extra_args = $1, $3, $4
        comment = "#{indent}# #{command["summary"].strip}."

        IO.popen("par p#{2 + indent.size} 80", "r+") do |io|
          io.puts comment
          io.close_write
          comment = io.read
        end

        "#{comment}#{extra_comments}#{indent}def #{name.downcase}#{extra_args}"
      end
    end

    File.open(file, "w") { |f| f.write(source) }
  end

  task :doc do
    document "lib/redis.rb"
    document "lib/redis/distributed.rb"
  end

  task :verify do
    require "redis"
    require "stringio"

    require "./test/helper"

    OPTIONS[:logger] = Logger.new("./tmp/log")

    Rake::Task["test:ruby"].invoke

    redis = Redis.new

    report = ["Command", "\033[0mDefined?\033[0m", "\033[0mTested?\033[0m"]

    yes, no = "\033[1;32mYes\033[0m", "\033[1;31mNo\033[0m"

    log = File.read("./tmp/log")

    redis_commands.sort.each do |name, _|
      defined, tested = redis.respond_to?(name), log[">> #{name.upcase}"]

      next if defined && tested

      report << name
      report << (defined ? yes : no)
      report << (tested ? yes : no)
    end

    IO.popen("rs 0 3", "w") do |io|
      io.puts report.join("\n")
    end
  end
end
