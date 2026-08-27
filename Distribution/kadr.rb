# Homebrew cask for Kadr (docs/04 §10, PRD §9).
#
# Lives here as the source of truth; releasing copies it into homebrew/homebrew-cask, or
# into a tap while the app is too new for the main repository.
#
# `sha256` and `version` are rewritten by Scripts/release.sh for each release.
cask "kadr" do
  version "0.0.0"
  sha256 :no_check

  url "https://github.com/kadr-app/kadr/releases/download/v#{version}/Kadr-#{version}.dmg",
      verified: "github.com/kadr-app/kadr/"
  name "Kadr"
  desc "Native screen-capture app that keeps everything on your Mac"
  homepage "https://github.com/kadr-app/kadr"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Sparkle handles its own updates, so Homebrew should not fight it.
  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Kadr.app"

  zap trash: [
    "~/Library/Application Support/Kadr",
    "~/Library/Preferences/app.kadr.Kadr.plist",
    "~/Library/Caches/app.kadr.Kadr",
  ]
end
