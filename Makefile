# szn Makefile
# Usage:
#   make release VERSION=1.2.0   — bump version, commit, tag, push → CI builds DMG + GitHub Release
#   make build                   — local build
#   make generate                — regenerate Xcode project from project.yml

.PHONY: release build generate clean

# ── Release ──────────────────────────────────────────────────────────
# Bumps version in project.yml, commits, tags, and pushes.
# GitHub Actions picks up the tag and creates the DMG + Release.
release:
ifndef VERSION
	$(error Usage: make release VERSION=x.y.z)
endif
	@echo "── Bumping version to $(VERSION)..."
	@sed -i '' 's/MARKETING_VERSION: ".*"/MARKETING_VERSION: "$(VERSION)"/' project.yml
	@git add project.yml
	@git diff --cached --quiet && echo "Version already $(VERSION), skipping commit." || git commit -m "release: v$(VERSION)"
	@git tag "v$(VERSION)"
	@echo "── Pushing commit and tag..."
	@git push && git push origin "v$(VERSION)"
	@echo "── Done! GitHub Actions will build the DMG and create the release."
	@echo "   https://github.com/realgarit/szn/actions"

# ── Local build ──────────────────────────────────────────────────────
generate:
	xcodegen generate

build: generate
	xcodebuild \
		-project szn.xcodeproj \
		-scheme szn \
		-configuration Release \
		-derivedDataPath build \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO

clean:
	rm -rf build DerivedData szn.xcodeproj
