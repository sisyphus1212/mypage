DIRECTORY="./source"
modify_files=$(find "$DIRECTORY" -type f -mmin -60)

IFS=$'\n'
for file in $modify_files; do
    if [[ $file == *.md ]]; then
        sed -i -E 's|\]\((\.\./)+medias/(image_[0-9]+)/([^)]+)\.png\)|\](https://github.com/sisyphus1212/\2/blob/main/\3.png?raw=true)|g' $file
    fi
done
