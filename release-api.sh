RELEASE_PATH=/opt/release/usermgr

rm -Rf $RELEASE_PATH
mkdir -p $RELEASE_PATH

cp -Rf ./src/api $RELEASE_PATH
rm -Rf $RELEASE_PATH/bkuser_global
cp -Rf ./src/bkuser_global $RELEASE_PATH/api/bkuser_global
cp -Rf ./src/api/support-files $RELEASE_PATH
cp -Rf ./VERSION $RELEASE_PATH
cp -Rf ./src/api/projects.yaml $RELEASE_PATH

cd $RELEASE_PATH
virtualenv venv -p python3
./venv/bin/pip3 download -r ./api/requirements.txt -d ./pkgs
rm -Rf ./venv

cd $RELEASE_PATH/api/bkuser_core/config/overlays
cp -Rf ./prod.py ./dev.py

