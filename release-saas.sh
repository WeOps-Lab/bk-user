cd ./src/pages
npm install
npm run build
cd ../..
RELEASE_PATH=/opt/release/bk_user_manage
rm -Rf $RELEASE_PATH
mkdir -p $RELEASE_PATH
cp -Rf ./src/saas $RELEASE_PATH/src
cp -Rf ./src/pages/dist $RELEASE_PATH/src/static
rm -Rf $RELEASE_PATH/src/bkuser_global
cp -Rf ./src/bkuser_global $RELEASE_PATH/src/
rm -Rf $RELEASE_PATH/src/bkuser_sdk
cp -Rf ./src/sdk/bkuser_sdk/ $RELEASE_PATH/src/
cp -Rf ./VERSION $RELEASE_PATH
cp -Rf ./src/saas/app.yml $RELEASE_PATH
cp -Rf ./src/saas/bk_user_manage.png $RELEASE_PATH
mkdir -p $RELEASE_PATH/pkgs

cd $RELEASE_PATH
virtualenv venv -p python3
./venv/bin/pip3 download -r ./src/requirements.txt -d $RELEASE_PATH/pkgs 
rm -Rf ./venv
#./venv/bin/pip3 download cffi==1.15.0  -i https://mirrors.cloud.tencent.com/pypi/simple -d $RELEASE_PATH/pkgs
#./venv/bin/pip3 download idna==2.1  -i https://mirrors.cloud.tencent.com/pypi/simple -d $RELEASE_PATH/pkgs
# pip3 download pycparser==2.2  -i https://mirrors.cloud.tencent.com/pypi/simple -d $RELEASE_PATH/pkgs 
# pip3 download aenum==2.2.1 -i https://mirrors.cloud.tencent.com/pypi/simple -d $RELEASE_PATH/pkgs 
# pip3 download wheel -i https://mirrors.cloud.tencent.com/pypi/simple -d $RELEASE_PATH/pkgs 
