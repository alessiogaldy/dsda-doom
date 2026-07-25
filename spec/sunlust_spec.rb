# Slaughter-map demos, excluded from the default run (see spec_helper).
# Lighter than the sunder suite -- seconds rather than minutes -- but still
# well above anything in sync_spec. Run with: rspec -t sunlust
RSpec.describe 'sunlust', :sunlust do
  let(:iwad) { "DOOM2.WAD" }
  let(:pwad) { "sunlust.wad" }
  let(:extra) { nil }

  before do
    Utility.play_demo(lmp: lmp, iwad: iwad, pwad: pwad, extra: extra)
  end

  describe 'total time' do
    subject { Utility.read_levelstat.total }

    lines = File.readlines('spec/support/lmps/sunlust/list.txt', chomp: true)
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
