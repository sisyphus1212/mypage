git_log_debug=$(git branch)
modify_files="$(git show --name-only --pretty=format:)"
echo "============"
echo $git_log_debug
echo "$modify_files"
echo "============"
IFS=$'\n'
for file in "$modify_files"; do
    if [[ $file == *.md ]]; then
        ls -lh $file
        sed -i -E 's|\]\((\.\./)+medias/(images_[0-9]+)/([^)]+)\.png\)|\](https://github.com/sisyphus1212/\2/blob/main/\3.png?raw=true)|g' $file
    fi
done
