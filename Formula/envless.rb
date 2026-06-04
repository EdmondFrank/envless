# Homebrew formula for envless.
#
# Distribution model — self-tap. Users install via:
#   brew tap biliboss/envless https://github.com/biliboss/envless
#   brew install biliboss/envless/envless
#
# `version` + the four `sha256` lines are kept in sync with the
# matching release tarballs by `.github/workflows/release.yml`, which
# rewrites this file on every `v*` tag push. Hand-edits to those
# fields will be lost on the next release. The structural shape of
# the formula (deps, install, test, caveats) is hand-maintained.
#
# Audit:
#   brew audit --strict --tap biliboss/envless
#
class Envless < Formula
  desc "Agent-first secrets manager — encrypted dotenv files in git via sops+age"
  homepage "https://biliboss.github.io/envless/"
  version "0.2.0"
  license "Apache-2.0"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/biliboss/envless/releases/download/v#{version}/envless_v#{version}_aarch64-macos.tar.gz"
      sha256 "4d39055e7d868e54e72ae85b5be80b717780375661bf7c2cce705985492962b0"
    else
      url "https://github.com/biliboss/envless/releases/download/v#{version}/envless_v#{version}_x86_64-macos.tar.gz"
      sha256 "acc941323d183bcc6fa1666f313d17e375e9699c012149c1444c2d439fef6d9c"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/biliboss/envless/releases/download/v#{version}/envless_v#{version}_aarch64-linux-gnu.tar.gz"
      sha256 "1934ee218238b15584da9c919b6270ff18aaa59fcd96a83ed74683e51a1cd0f9"
    else
      url "https://github.com/biliboss/envless/releases/download/v#{version}/envless_v#{version}_x86_64-linux-gnu.tar.gz"
      sha256 "10a5685ca41f51dcf9fff961bf4eab2b36329f70c29027775d6991962d436f4e"
    end
  end

  # envless shells out to these two binaries; they are not bundled.
  depends_on "age"
  depends_on "sops"

  def install
    bin.install "envless"
  end

  def caveats
    <<~EOS
      envless requires `age` and `sops` on PATH. Both were just installed as
      dependencies of this formula.

      Initialise a repo:
        cd <your-project>
        envless init
        envless set OPENAI_API_KEY --env=dev
        envless exec --env=dev -- your-app

      Docs: https://biliboss.github.io/envless/
    EOS
  end

  test do
    assert_match "envless v#{version}", shell_output("#{bin}/envless --version")
  end
end
