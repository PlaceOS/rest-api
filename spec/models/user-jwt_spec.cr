require "../helper"

module ACAEngine::Model
  # Sample data
  USER_META = UserJWT::Metadata.new(
    name: "abcde",
    email: "abcde@protonmail.com",
    admin: true,
    support: true,
  )

  ATTRIBUTES = {
    iss:  "ACAE",
    iat:  Time.unix(1000),
    exp:  Time.unix(Int32::MAX),
    aud:  "protonmail.com",
    sub:  "1234",
    user: USER_META,
  }

  ALGORITHM = JWT::Algorithm::RS256
  KEY       = <<-KEY
  -----BEGIN RSA PRIVATE KEY-----
  MIIEpAIBAAKCAQEAt01C9NBQrA6Y7wyIZtsyur191SwSL3MjR58RIjZ5SEbSyzMG
  3r9v12qka4UtpB2FmON2vwn0fl/7i3Jgh1Xth/s+TqgYXMebdd123wodrbex5pi3
  Q7PbQFT6hhNpnsjBh9SubTf+IeTIFeXUyqtqcDBmEoT5GxU6O+Wuch2GtbfEAmaD
  roy+uyB7P5DxpKLEx8nlVYgpx5g2mx2LufHvykVnx4bFzLezU93SIEW6yjPwUmv9
  R+wDM/AOg60dIf3hCh1DO+h22aKT8D8ysuFodpLTKCToI/AbK4IYOOgyGHZ7xizX
  HYXZdsqX5/zBFXu/NOVrSd/QBYYuCxbqe6tz4wIDAQABAoIBAQCEIRxXrmXIcMlK
  36TfR7h8paUz6Y2+SGew8/d8yvmH4Q2HzeNw41vyUvvsSVbKC0HHIIfzU3C7O+Lt
  9OeiBo2vTKrwNflBv9zPDHHoerlEBLsnNwQ7uEUeTWM9DHdBLwNaLzQApLD6q5iT
  OFW4NfIGpsydIt8R565PiNPDjIcTKwhbVdlsSbI87cLkQ9UuYIMRkvXSD1Q2cg3I
  VsC0SpE4zmfTe7YTZQ5yTxtsoLKPBXrSxhhGuhdayeN7A4YHFYVD39RuQ6/T2w2a
  W/0UaGOk8XWgydDpD5w9wiBdH2I4i6D35IynCcodc5JvmTajzJT+xj6aGjjvMSyq
  q5ZdwJ4JAoGBAOPdZgjbOCf3ONUoiZ5Qw/a4b4xJgMokgqZ5QGBF5GqV1Xsphmk1
  apYmgC7fmab/EOdycrQMS0am2FmtwX1f7gYgJoyWtK4TVkUc5rf+aoWi0ieIsegv
  rjhuiIAc12+vVIbegRgnq8mOI5icrwm6OkwdqHkwTt6VRYdJGEmu67n/AoGBAM3v
  RAd5uIjVwVDLXqaOpvF3pxWfl+cf6PJtAE5y+nbabeTmrw//fJMank3o7qCXkFZR
  F0OJ2tmENwV+LPM8Gy3So8YP2nkOz4bryaGrxQ4eMA+K9+RiACVaKv+tNx/NbyMS
  e9gg504u0cwa60XjM5KUKrmT3RXpY4YIfUPZ1J4dAoGAB6jalDOiSJ2j2G57acn3
  PGTowwN5g9IEXko3IsVWr0qIGZLExOaZxaBXsLutc5KhY9ZSCsFbCm3zWdhgZ7GA
  083i3dj3C970iHA3RToVJJbbj56ltFNd/OGiTwQpLcTsB3iVSFWVDbpsceXacG5F
  JWfd0O0RyaOk6a5IVbm+jMsCgYBglxAOfY4LSE8y6SCM+K3e5iNNZhymgHYPdwbE
  xPMrWgpfab/Evi2dBcgofM+oLU663bAOspMeoP/5qJPGxnNtC7ZbSMZNL6AxBVj+
  ZoW3uHsMXz8kNL8ixecTIxiO5xlwltPVrKExL46hsCKYFhfzcWGUx4DULTLMBCFU
  +M/cFQKBgQC+Ite962yJOnE+bjtSReOrvR9+I+YNGqt7vyRa2nGFxL7ZNIqHss5T
  VjaMgjzVJqqYozNT/74pE/b9UjYyMzO/EhrjUmcwriMMan/vTbYoBMYWvGoy536r
  4n455vizig2c4/sxU5yu9AF9Dv+qNsGCx2e9uUOTDUlHM9NXwxU9rQ==
  -----END RSA PRIVATE KEY-----
  KEY

  SAMPLE_JWT = "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.eyJpc3MiOiJBQ0FFIiwiaWF0IjoxMDAwLCJleHAiOjIxNDc0ODM2NDcsImF1ZCI6InByb3Rvbm1haWwuY29tIiwic3ViIjoiMTIzNCIsInVzZXIiOnsibmFtZSI6ImFiY2RlIiwiZW1haWwiOiJhYmNkZUBwcm90b25tYWlsLmNvbSIsImFkbWluIjp0cnVlLCJzdXBwb3J0Ijp0cnVlfX0.OWem13XxhN9j-ivgR9tfmcnbqzk3J_d4buC_-UdDcxZ6mIHTVt2GrNoEHTJrcBIiBWAO_UsfSIy4lP-jNnRlHN9MSRzTQFLvHKxQbQNWEQ3vFwuTYscESDxjJWKd__RF_7t_J_AkYVraaiXKuHgXu5o4xJ9OR3JuW2Z4pVmq63gXcb5fdexE5jMUySQ6oZ8Pk7VxJdRMDhyMOfnK7aQ-UXL6Us9tXMD-_XItp9Ko_JOJkJeGtVEU4vIX5G6UdCMzCe5cGB1nbm_70MdCKNoqEopSuDn0JvMngh69_ylTlB1wvHHFIWsW9SDKDaWlfhs-YW10kIysKEq4bd3j-veWMA"

  describe UserJWT do
    it "satisfies round trip property" do
      user_jwt = Generator.user_jwt
      token = user_jwt.encode
      decoded_jwt = UserJWT.decode(token)

      decoded_jwt.id.should eq user_jwt.id
      decoded_jwt.domain.should eq user_jwt.domain
      decoded_jwt.user.email.should eq user_jwt.user.email
      decoded_jwt.user.admin.should eq user_jwt.user.admin
      decoded_jwt.user.support.should eq user_jwt.user.support
    end

    it "encodes" do
      user_jwt = UserJWT.new(**ATTRIBUTES)
      user_jwt.encode(KEY, ALGORITHM).should eq SAMPLE_JWT
    end

    it "decodes" do
      user_jwt = UserJWT.new(**ATTRIBUTES)
      decoded_jwt = UserJWT.decode(SAMPLE_JWT, KEY, ALGORITHM)

      decoded_jwt.id.should eq user_jwt.id
      decoded_jwt.domain.should eq user_jwt.domain
      decoded_jwt.user.email.should eq user_jwt.user.email
      decoded_jwt.user.admin.should eq user_jwt.user.admin
      decoded_jwt.user.support.should eq user_jwt.user.support
    end
  end
end
