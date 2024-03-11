---
title: vscode-git-自动push
date: 2023-11-01 18:21:45
categories:
- [其它]
tags: vscode
---
在利用vscode写笔记时可以利用File Watcher 插件来实现git的自动pull 和 push

配置如下：
```json
    "filewatcher.commands": [
        {
            "match": "\\.*",
            "isAsync": true,
            "cmd": "pushd ${fileDirname} && git pull && git add . && git commit -m auto_update && git push -f",
            "event": "onFileChange"
        }
    ]
```

