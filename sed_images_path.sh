modify_files="$(git show --stat --name-only --pretty=format:)"
echo "============"
echo "$modify_files"
echo "============"
IFS=$'\n'
for file in "$modify_files"; do
    if [[ $file == *.md ]]; then
        sed -i -E 's|\]\((\.\./)+medias/(images_[0-9]+)/([^)]+)\.png\)|\](https://github.com/sisyphus1212/\2/blob/main/\3.png?raw=true)|g' $file
        cat $file
    fi
done
