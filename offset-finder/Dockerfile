FROM ghcr.io/camertron/anaconda3:2023.07-1
WORKDIR /app
COPY requirements.txt /app
RUN pip3 install -r requirements.txt
COPY . /app
ENTRYPOINT ["python3", "bmm.py"]
