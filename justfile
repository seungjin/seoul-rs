prebuild:
    cat config/config.toml config/author.toml > zola.toml

localrun: && prebuild
    zola serve --drafts
