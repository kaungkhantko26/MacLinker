cask "maclinker" do
  version "1.5.0"
  sha256 "042cd9b7428e4d85daec82fa7b95df2988db9b20fc91aa6c27fe7b51f3ed4f8e"

  url "https://github.com/kaungkhantko26/MacLinker/releases/download/v#{version}/MacLinker.zip"
  name "MacLinker"
  desc "Share keyboard, mouse, clipboard and files between Macs"
  homepage "https://github.com/kaungkhantko26/MacLinker"

  depends_on macos: ">= :ventura"

  app "MacLinker.app"

  # The app isn't notarized by Apple, so clear the download quarantine flag.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/MacLinker.app"]
  end

  zap trash: [
    "~/Library/Application Support/MacLinker",
    "~/Library/Logs/MacLinker-update.log",
    "~/Library/Preferences/com.maclinker.app.plist",
    "~/Downloads/MacLinker",
  ]
end
