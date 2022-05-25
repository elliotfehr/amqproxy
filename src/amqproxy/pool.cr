module AMQProxy
  class Pool
    getter :size

    def initialize(@host : String, @port : Int32, @tls : Bool, @metrics_client : MetricsClient, @log : Logger, @idle_connection_timeout : Int32)
      @pools = Hash(Tuple(String, String, String), Deque(Upstream)).new do |h, k|
        h[k] = Deque(Upstream).new
      end
      @lock = Mutex.new
      @size = 0
      spawn shrink_pool_loop, name: "shrink pool loop"
    end

    def borrow(user : String, password : String, vhost : String, &block : Upstream -> _)
      max_attempts = 10
      attempts = 0
      has_connection = false
      while has_connection == false && attempts < max_attempts
        max_attempts += 1
        begin
          u = get_upstream(user, password, vhost)
          yield u
        ensure
          if u.nil?
            @size -= 1
            @log.error "Upstream connection could not be established"
          elsif u.closed?
            @size -= 1
            @log.error "Upstream connection closed when returned"
          else
            has_connection = true
            u.last_used = Time.monotonic
            @lock.synchronize do
              @pools[{ user, password, vhost }].push u
            end
          end
        end
      end
    end

    def close
      @lock.synchronize do
        @pools.each_value do |q|
          while u = q.shift?
            begin
              u.close "AMQProxy shutdown"
            rescue ex
              @log.error "Problem closing upstream: #{ex.inspect}"
            end
          end
        end
        @size = 0
      end
    end

    private def get_upstream(user : String, password : String, vhost : String)
      @lock.synchronize do
        q = @pools[{ user, password, vhost }]
        q.shift do
          @size += 1
          @metrics_client.increment("connections.upstream.created", 1)
          Upstream.new(@host, @port, @tls, @log).connect(user, password, vhost)
        end
      end
    end

    private def shrink_pool_loop
      loop do
        sleep 5.seconds
        @lock.synchronize do
          max_connection_age = Time.monotonic - @idle_connection_timeout.seconds
          @pools.each_value do |q|
            q.size.times do
              u = q.shift
              if u.last_used < max_connection_age
                @size -= 1
                begin
                  u.close "Pooled connection closed due to inactivity"
                  @metrics_client.increment("connections.upstream.closed", 1)
                rescue ex
                  @log.error "Problem closing upstream: #{ex.inspect}"
                end
              else
                q.push u
              end
            end
          end
        end
        @metrics_client.gauge("connections.upstream.total", @size)
      end
    end
  end
end
