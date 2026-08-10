. as $configuration
| $pin[0] as $pin
| .schema_version == 1
and .distribution_repository == $pin.repository
and ($pin.release.tag | test($configuration.release_tag_pattern))
and ($configuration.release_tag_example | test($configuration.release_tag_pattern))
and .upstream.repository == $pin.upstream.repository
and .upstream.commit == $pin.upstream.commit
and .upstream.source_version == $pin.upstream.sourceVersion
and .upstream.artifact_version == $pin.artifactVersion
and .immutable_releases_required == true
and ((.artifacts | sort) == [
    "FocusRustComponents.xcframework.zip",
    "MozillaRustComponents.xcframework.zip",
    "swift-components.tar.xz"
])
