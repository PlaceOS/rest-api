require "./helper"

module PlaceOS::Api
  describe ImageGen do
    describe ".editable_size" do
      it "keeps the source shape for a poster that is already a legal size" do
        # the 2:3 schedule poster, the case that came back reframed to 9:16
        size = ImageGen.editable_size(1080, 1440).not_nil!
        width, height = size.split('x').map(&.to_i)
        (width / height.to_f).should be_close(1080 / 1440.0, 0.02)
        (width % 16).should eq 0
        (height % 16).should eq 0
      end

      it "scales a small source up over the vendor's floor" do
        size = ImageGen.editable_size(535, 693).not_nil!
        width, height = size.split('x').map(&.to_i)
        (width * height).should be >= 655_360
        (width / height.to_f).should be_close(535 / 693.0, 0.02)
      end

      it "scales an oversized source down under the ceiling" do
        size = ImageGen.editable_size(8000, 6000).not_nil!
        width, height = size.split('x').map(&.to_i)
        (width * height).should be <= 8_294_400
        width.should be <= 3840
        height.should be <= 3840
        (width / height.to_f).should be_close(8000 / 6000.0, 0.02)
      end

      it "gives up on a shape the vendor will not draw" do
        # 5:1 banner, past the 3:1 limit: the aspect table takes over
        ImageGen.editable_size(5000, 1000).should be_nil
        ImageGen.editable_size(1000, 5000).should be_nil
      end

      it "refuses nonsense" do
        ImageGen.editable_size(0, 100).should be_nil
        ImageGen.editable_size(-10, 100).should be_nil
      end

      it "always lands on something the vendor accepts" do
        {
          {1920, 1080}, {1080, 1920}, {1024, 1024}, {2480, 3508},
          {800, 600}, {3000, 1200}, {640, 480}, {4096, 4096},
        }.each do |(width, height)|
          size = ImageGen.editable_size(width, height)
          next if size.nil?
          w, h = size.split('x').map(&.to_i)
          (w % 16).should eq 0
          (h % 16).should eq 0
          (w * h).should be >= 655_360
          (w * h).should be <= 8_294_400
          w.should be <= 3840
          h.should be <= 3840
        end
      end
    end
  end
end
