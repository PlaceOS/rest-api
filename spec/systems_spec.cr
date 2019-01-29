require "./spec_helper"

describe Welcome do
  # ==============
  #  Unit Testing
  # ==============
  it "should generate a date string" do
    # instantiate the controller you wish to unit test
    #welcome = Welcome.new(context("GET", "/"))

    # Test the instance methods of the controller
    #welcome.set_date_header[0].should contain("GMT")
  end

  # ==============
  # Test Responses
  # ==============
  with_server do
    it "should return a list of sytems" do
      result = curl("GET", "/")
      result.body.includes?("You're being trampled by Spider-Gazelle!").should eq(true)
    end
  end
end
