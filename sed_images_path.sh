set -x
echo "1"
#modify_files="$(git config --global core.quotepath false;git show --stat --name-only --pretty=format:)"
modify_files=`find . -name "*.md"`
echo "============"
echo "$modify_files"
echo "============"

IFS=$'\n'
for file in "$modify_files"; do
    file="${file//\"/}"
    if [[ $file == *.md ]]; then
        echo "++++++++++++++"
        sed -i -E 's|\]\((\.\./)+medias/(images_[0-9]+)/([^)]+)\.png\)|\](https://github.com/sisyphus1212/\2/blob/main/\3.png?raw=true)|g' $file
        #cat $file
        echo "++++++++++++++"
    fi
done
