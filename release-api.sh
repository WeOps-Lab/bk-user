RELEASE_PATH=/opt/release/usermgr

rm -Rf $RELEASE_PATH
mkdir -p $RELEASE_PATH

cp -Rf ./src/api $RELEASE_PATH
rm -Rf $RELEASE_PATH/bkuser_global
cp -Rf ./src/bkuser_global $RELEASE_PATH/api/bkuser_global
cp -Rf ./src/api/support-files $RELEASE_PATH
cp -Rf ./VERSION $RELEASE_PATH
cp -Rf ./src/api/projects.yaml $RELEASE_PATH
pip3 download  -i https://mirrors.cloud.tencent.com/pypi/simple -r ./src/api/requirements.txt -d $RELEASE_PATH/pkgs


