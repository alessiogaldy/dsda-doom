module Utility
  extend self

  # Override with DSDA_DOOM to test a binary from another build system,
  # e.g. DSDA_DOOM=./zig-out/bin/dsda-doom rspec
  BINARY = ENV.fetch("DSDA_DOOM", "./zig-out/bin/dsda-doom")

  # Written into the working directory by -levelstat and -analysis.
  OUTPUT_FILES = ["levelstat.txt", "analysis.txt"].freeze

  def play_demo(lmp:, iwad: "DOOM2.WAD", pwad: nil, extra: nil)
    # Clear previous output first. Without this, a demo that produces no
    # output at all leaves the previous example's file in place and the
    # expectation silently reads *that* -- so the failure reported is a
    # stale number from an unrelated test rather than an honest error.
    OUTPUT_FILES.each { |f| File.delete(f) if File.exist?(f) }

    command = "#{BINARY} -iwad spec/support/wads/#{iwad}"
    command << " -file spec/support/wads/#{pwad}" if pwad
    command << " -fastdemo \"spec/support/lmps/#{lmp}\""
    command << " -nosound -nomusic -nodraw -levelstat -analysis"
    command << " #{extra}" if extra

    system(command)
  end

  def read_analysis
    Analysis.new
  end

  def read_levelstat(filename = "levelstat.txt")
    Levelstat.new(filename)
  end

  class Analysis
    def initialize
      @data = Hash[
        File.readlines("analysis.txt", chomp: true).map(&:split).map do |a|
          [a[0], a[1..].join(' ')]
        end
      ]
    end

    def skill
      @data['skill'].to_i
    end

    def nomonsters?
      @data['nomonsters'] == '1'
    end

    def respawn?
      @data['respawn'] == '1'
    end

    def fast?
      @data['fast'] == '1'
    end

    def pacifist?
      @data['pacifist'] == '1'
    end

    def stroller?
      @data['stroller'] == '1'
    end

    def reality?
      @data['reality'] == '1'
    end

    def almost_reality?
      @data['almost_reality'] == '1'
    end

    def hundred_k?
      @data['100k'] == '1'
    end

    def hundred_s?
      @data['100s'] == '1'
    end

    def missed_monsters
      @data['missed_monsters'].to_i
    end

    def missed_secrets
      @data['missed_secrets'].to_i
    end

    def tyson_weapons?
      @data['tyson_weapons'] == '1'
    end

    def turbo?
      @data['turbo'] == '1'
    end

    def weapon_collector?
      @data['weapon_collector'] == '1'
    end

    def category
      @data['category']
    end
  end

  class Levelstat
    def initialize(filename)
      @data = File.readlines(filename, chomp: true).map(&:split)
    end

    def total
      return '00:00' unless @data.last

      @data.last[3].gsub(/[()]/, '')
    end
  end
end
