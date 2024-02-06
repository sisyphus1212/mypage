DIRECTORY="./source"
modify_files=$(find "$DIRECTORY" -type f -mmin -60)

IFS=$'\n'
for file in $modify_files; do
    if [[ $file == *.md ]]; then
        stat $file
        sed -i -E 's|\]\((\.\./)+medias/(images_[0-9]+)/([^)]+)\.png\)|\](https://github.com/sisyphus1212/\2/blob/main/\3.png?raw=true)|g' $file
    fi
done
