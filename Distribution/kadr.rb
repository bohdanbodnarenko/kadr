# Homebrew cask for Kadr (docs/04 §10, PRD §9).
#
# Lives here as the source of truth; releasing copies it into homebrew/homebrew-cask, or
# into a tap while the app is too new for the main repository.
#
# `sha256` and `version` are rewritten by Scripts/release.sh for each release. The version
# is "<marketing>,<build>" because releases are tagged v<marketing>-b<build> (T-REL-5).
cask "kadr" do
  version "0.0.0,0"
  sha256 :no_check

  url "https://github.com/bohdanbodnarenko/kadr/releases/download/v#{version.csv.first}-b#{version.csv.second}/Kadr-#{version.csv.first}.dmg",
      verified: "github.com/bohdanbodnarenko/kadr/"
  name "Kadr"
  desc "Native screen-capture app that keeps everything on your Mac"
  homepage "https://github.com/bohdanbodnarenko/kadr"

  # The appcast, not GitHub's "latest": it knows the build number the version needs.
  livecheck do
    url "https://raw.githubusercontent.com/bohdanbodnarenko/kadr/main/appcast.xml"
    strategy :sparkle do |item|
      "#{item.short_version},#{item.version}"
    end
  end

  # Sparkle handles its own updates, so Homebrew should not fight it.
  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Kadr.app"

  zap trash: [
    "~/Library/Application Support/Kadr",
    "~/Library/Caches/app.kadr.Kadr",
    "~/Library/Caches/app.kadr.Kadr.Editor",
    "~/Library/HTTPStorages/app.kadr.Kadr",
    "~/Library/HTTPStorages/app.kadr.Kadr.binarycookies",
    "~/Library/Preferences/app.kadr.Kadr.plist",
    "~/Library/Preferences/app.kadr.Kadr.Editor.plist",
    "~/Library/Saved Application State/app.kadr.Kadr.savedState",
    "~/Library/Saved Application State/app.kadr.Kadr.Editor.savedState",
  ]
end
