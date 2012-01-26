require "filewatch/buftok"
require "filewatch/watch"
require "logger"

module FileWatch
  class Tail
    # how often (in seconds) we @logger.warn a failed file open, per path.
    OPEN_WARN_INTERVAL = ENV["FILEWATCH_OPEN_WARN_INTERVAL"] ?
                         ENV["FILEWATCH_OPEN_WARN_INTERVAL"].to_i : 300

    attr_accessor :logger

    public
    def initialize(opts={})
      if opts[:logger]
        @logger = opts[:logger]
      else
        @logger = Logger.new(STDERR)
        @logger.level = Logger::INFO
      end
      @files = {}
      @lastwarn = Hash.new { |h, k| h[k] = 0 }
      @buffers = {}
      @watch = FileWatch::Watch.new
      @watch.logger = @logger
      @sincedb = {}
      @sincedb_last_write = 0
      @statcache = {}
      @opts = {
        :sincedb_write_interval => 10,
        :sincedb_path => ENV["SINCEDB_PATH"] || File.join(ENV["HOME"], ".sincedb"),
        :stat_interval => 1,
        :discover_interval => 5,
        :exclude => [],
      }.merge(opts)
      @watch.exclude(@opts[:exclude])

      _sincedb_open
    end # def initialize

    public
    def logger=(logger)
      @logger = logger
      @watch.logger = logger
    end # def logger=

    public
    def tail(path)
      @watch.watch(path)
    end # def tail

    public
    def subscribe(&block)
      # subscribe(stat_interval = 1, discover_interval = 5, &block)
      @watch.subscribe(@opts[:stat_interval],
                       @opts[:discover_interval]) do |event, path|
        case event
        when :create, :create_initial
          if @files.member?(path)
            @logger.debug("#{event} for #{path}: already exists in @files")
            next
          end
          if _open_file(path, event)
            _read_file(path, &block)
          end
        when :modify
          if !@files.member?(path)
            @logger.debug(":modify for #{path}, does not exist in @files")
            if _open_file(path, event)
              _read_file(path, &block)
            end
          else
            _read_file(path, &block)
          end
        when :delete
          @logger.debug(":delete for #{path}, deleted from @files")
          _read_file(path, &block)
          @files[path].close
          @files.delete(path)
          @statcache.delete(path)
        else
          @logger.warn("unknown event type #{event} for #{path}")
        end
      end # @watch.subscribe
    end # def each

    private
    def _open_file(path, event)
      @logger.debug("_open_file: #{path}: opening")
      begin
        @files[path] = File.open(path)
      rescue
        # don't emit this message too often. if a file that we can't
        # read is changing a lot, we'll try to open it more often,
        # and might be spammy.
        now = Time.now.to_i
        if now - @lastwarn[path] > OPEN_WARN_INTERVAL
          @logger.warn("failed to open #{path}: #{$!}")
          @lastwarn[path] = now
        else
          @logger.debug("(warn supressed) failed to open #{path}: #{$!}")
        end
        @files.delete(path)
        return false
      end

      stat = File::Stat.new(path)
      inode = [stat.ino, stat.dev_major, stat.dev_minor]
      @statcache[path] = inode

      if @sincedb.member?(inode)
        last_size = @sincedb[inode]
        @logger.debug("#{path}: sincedb last value #{@sincedb[inode]}, cur size #{stat.size}")
        if last_size <= stat.size
          @logger.debug("#{path}: sincedb: seeking to #{last_size}")
          @files[path].sysseek(last_size, IO::SEEK_SET)
        else
          @logger.debug("#{path}: last value size is greater than current value, starting over")
          @sincedb[inode] = 0
        end
      elsif event == :create_initial && @files[path]
        @logger.debug("#{path}: initial create, no sincedb, seeking to end #{stat.size}")
        @files[path].sysseek(stat.size, IO::SEEK_SET)
        @sincedb[inode] = stat.size
      else
        @logger.debug("#{path}: staying at position 0, no sincedb")
      end

      return true
    end # def _open_file

    private
    def _read_file(path, &block)
      @buffers[path] ||= FileWatch::BufferedTokenizer.new

      changed = false
      loop do
        begin
          data = @files[path].read_nonblock(4096)
          changed = true
          @buffers[path].extract(data).each do |line|
            yield(path, line)
          end

          @sincedb[@statcache[path]] = @files[path].pos
        rescue Errno::EWOULDBLOCK, Errno::EINTR, EOFError
          break
        end
      end

      if changed
        now = Time.now.to_i
        delta = now - @sincedb_last_write
        if delta >= @opts[:sincedb_write_interval]
          @logger.debug("writing sincedb (delta since last write = #{delta})")
          _sincedb_write
          @sincedb_last_write = now
        end
      end
    end # def _read_file

    public
    def sincedb_write(reason=nil)
      @logger.debug("caller requested sincedb write (#{reason})")
      _sincedb_write
    end

    private
    def _sincedb_open
      path = @opts[:sincedb_path]
      begin
        db = File.open(path)
      rescue
        @logger.debug("_sincedb_open: #{path}: #{$!}")
        return
      end

      @logger.debug("_sincedb_open: reading from #{path}")
      db.each do |line|
        ino, dev_major, dev_minor, pos = line.split(" ", 4)
        inode = [ino.to_i, dev_major.to_i, dev_minor.to_i]
        @logger.debug("_sincedb_open: setting #{inode.inspect} to #{pos.to_i}")
        @sincedb[inode] = pos.to_i
      end
    end # def _sincedb_open

    private
    def _sincedb_write
      path = @opts[:sincedb_path]
      begin
        db = File.open(path, "w")
      rescue
        @logger.debug("_sincedb_write: #{path}: #{$!}")
        return
      end

      @sincedb.each do |inode, pos|
        db.puts([inode, pos].flatten.join(" "))
      end
      db.close
    end # def _sincedb_write
  end # class Watch
end # module FileWatch
