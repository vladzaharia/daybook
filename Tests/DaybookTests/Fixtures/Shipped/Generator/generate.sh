#!/bin/bash
# Remakes ../v0.1.0-preview and ../v0.2.2 with each tag's own code (README.md, "How they were made").
# Usage: generate.sh [work directory]. Needs the tags, Swift 6, and no network.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
fixtures="$(dirname "$here")"
repo="$(git -C "$here" rev-parse --show-toplevel)"
work="${1:-$(mktemp -d -t daybook-shipped-fixtures)}"
mkdir -p "$work"

show() { git -C "$repo" show "$1:$2"; }

# Keeps the files each version wrote for good; recovery copies on first save are byte-identical.
install_fixtures() {
  local out="$1" destination="$2" meeting
  mkdir -p "$destination/Library/Meetings" "$destination/Capture"
  cp "$out/defaults.plist" "$destination/"
  cp "$out/Library/library.json" "$out/Library/glossary.json" "$destination/Library/"
  for meeting in "$out"/Library/Meetings/*; do
    mkdir -p "$destination/Library/Meetings/$(basename "$meeting")"
    cp "$meeting/meeting.json" "$destination/Library/Meetings/$(basename "$meeting")/"
  done
  cp "$out"/Capture/*.json "$destination/Capture/"
}

# v0.1.0-preview: its whole DaybookCore, plus the app's Codable capture and preference types, which
# sit in files that also need AppKit, ScreenCaptureKit, or FluidAudio.
make_v010() {
  local tag=v0.1.0-preview package="$work/v0.1.0-preview" file
  mkdir -p "$package/Sources/OldCore" "$package/Sources/Gen"
  while IFS= read -r file; do
    show "$tag" "$file" > "$package/Sources/OldCore/$(basename "$file")"
  done < <(git -C "$repo" ls-tree --name-only "$tag" Sources/DaybookCore/)
  {
    echo "import Foundation"
    echo "// $tag: Sources/Daybook/Capture/RecordingController.swift, lines 8-41."
    show "$tag" Sources/Daybook/Capture/RecordingController.swift | sed -n 8,41p
    echo "// $tag: Sources/Daybook/App/ProcessingPreferences.swift, lines 4-46."
    show "$tag" Sources/Daybook/App/ProcessingPreferences.swift | sed -n 4,46p
    echo "// $tag: Sources/Daybook/Intelligence/SpeakerAnalysisOptions.swift, lines 4-35 (not its FluidAudio configuration)."
    show "$tag" Sources/Daybook/Intelligence/SpeakerAnalysisOptions.swift | sed -n 4,35p
    echo "}"
    echo "// $tag: Sources/Daybook/Intelligence/ModelCatalog.swift."
    echo 'enum DaybookModelCatalog { static let diarization = "speaker-community-1" }'
  } > "$package/Sources/Gen/OldApp.swift"
  cp "$here/v0.1.0-preview.swift" "$package/Sources/Gen/main.swift"
  cat > "$package/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Gen", platforms: [.macOS(.v15)],
    targets: [.target(name: "OldCore"), .executableTarget(name: "Gen", dependencies: ["OldCore"])],
    swiftLanguageModes: [.v5])
EOF
  (cd "$package" && swift run Gen "$work/out-$tag")
  install_fixtures "$work/out-$tag" "$fixtures/$tag"
}

# v0.2.2: its library targets as its Package.swift declared them, plus the app's capture types.
make_v022() {
  local tag=v0.2.2 package="$work/v0.2.2"
  mkdir -p "$package/Sources/Gen"
  git -C "$repo" archive "$tag" Sources/DaybookCore Sources/DaybookCaptions Sources/DaybookDevices Sources/DaybookLink \
    Sources/DaybookKit | tar -x -C "$package"
  {
    echo "// $tag: Sources/Daybook/Capture/CaptureModels.swift, lines 1-145 and 171-190."
    show "$tag" Sources/Daybook/Capture/CaptureModels.swift | sed -n 1,145p
    show "$tag" Sources/Daybook/Capture/CaptureModels.swift | sed -n 171,190p
    echo "// $tag: Sources/Daybook/Capture/AudioRouteMonitor.swift, lines 1-48."
    show "$tag" Sources/Daybook/Capture/AudioRouteMonitor.swift | sed -n 1,48p
    echo "// $tag: Sources/Daybook/Capture/MeetingDetection.swift, lines 28-35."
    show "$tag" Sources/Daybook/Capture/MeetingDetection.swift | sed -n 28,35p
    echo "}"
  } > "$package/Sources/Gen/OldApp.swift"
  cp "$here/v0.2.2.swift" "$package/Sources/Gen/main.swift"
  cat > "$package/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Gen", platforms: [.macOS(.v15)],
    targets: [
        .target(name: "DaybookCore"),
        .target(name: "DaybookLink"),
        .target(name: "DaybookCaptions"),
        .target(name: "DaybookDevices", dependencies: ["DaybookCore", "DaybookCaptions"]),
        .target(name: "DaybookKit", dependencies: ["DaybookCore", "DaybookDevices", "DaybookLink"],
                resources: [.copy("Resources/ModelCatalog")]),
        .executableTarget(name: "Gen", dependencies: ["DaybookCore", "DaybookDevices", "DaybookKit"])
    ],
    swiftLanguageModes: [.v5])
EOF
  (cd "$package" && swift run Gen "$work/out-$tag")
  install_fixtures "$work/out-$tag" "$fixtures/$tag"
}

make_v010
make_v022
echo "Fixtures written to $fixtures (work in $work)."
