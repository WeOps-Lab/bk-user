FROM python:3.6.8
WORKDIR /apps
ADD ./src/api ./api
RUN rm -Rf /apps/bkuser_global
ADD ./src/bkuser_global ./api/bkuser_global
ADD ./src/api/support-files ./support-files 
ADD ./VERSION ./VERSION
ADD ./src/api/projects.yaml ./projects.yaml
RUN cp -Rf ./api/bkuser_core/config/overlays/prod.py ./api/bkuser_core/config/overlays/dev.py
RUN pip3 install -i https://mirrors.tencent.com/pypi/simple -r ./api/requirements.txt
	
	