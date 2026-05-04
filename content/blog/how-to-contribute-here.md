+++
title = "How to write on seoul.rs"
date = "2026-03-13"
[taxonomies]
authors = ["Seungjin Kim"]
tags = ["howto"]
+++

This post was originally written in Korean [How to Contribute here](https://seoul.rs/ko/blog/how-to-contribute-here/) and translated into English with the help of an LLM.  

seoul.rs is built with [zola](https://getzola.org), a Rust-based Static Site Generator (SSG), and utilizes the [zola-bearblog](https://codeberg.org/alinnow/zola-bearblog) template.  

To contribute a blog post or news article, please fork [github.com/seoul-rs/seoul-rs](https://github.com/seoul-rs/seoul-rs). Create a Markdown (.md) file under the blog or news directory within the content folder. Each post must include a header in the format shown below, followed by your content in Markdown. For posts written in Korean, please include the `.ko` language tag in the filename (e.g., my-first-writing.ko.md). For English posts, simply use the .md extension (e.g., my-first-writing.md).  
```
+++
title = "How to write on seoul.rs"
date = "2026-03-03"
[taxonomies]
authors = ["John Smith"]
tags = ["first"]
+++

Start writing here...

```

Once you have finished writing, please submit a Pull Request to the [github.com/seoul-rs/seoul-rs](https://github.com/seoul-rs/seoul-rs) repository. Your post will be reviewed and merged, after which it will be automatically published via GitHub Actions.  

When creating a Pull Request, please ensure that all commits are signed with your encryption key. We only merge commits that are Verified using keys registered with GitHub. If you do not have a GitHub account, please submit your patch files signed with your GPG key.  

For more detailed information on the Static Site Generator (SSG), please refer to [Zola](https://getzola.org).


