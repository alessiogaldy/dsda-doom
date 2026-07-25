# Slaughter-map demos, excluded from the default run (see spec_helper).
# These are minutes of wall clock each, not seconds -- they exist to exercise
# the playsim at Sunder scale, where thinker counts and line-of-sight checks
# dominate. Run with: rspec -t sunder
RSpec.describe 'sunder', :sunder do
  let(:iwad) { "DOOM2.WAD" }
  let(:pwad) { "sunder2512.wad" }
  let(:extra) { nil }

  before do
    Utility.play_demo(lmp: lmp, iwad: iwad, pwad: pwad, extra: extra)
  end

  describe 'total time' do
    subject { Utility.read_levelstat.total }

    lines = File.readlines('spec/support/lmps/sunder/list.txt', chomp: true)
    lines.map! { |line| line.split('|') }

    lines.each do |lmp_description, lmp_time, lmp_file, extra|
      context lmp_description do
        let(:lmp) { lmp_file }
        let(:extra) { extra }

        it { is_expected.to eq(lmp_time) }
      end
    end
  end
end
