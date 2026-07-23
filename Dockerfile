FROM ubuntu:22.04

WORKDIR /app

COPY . .

RUN apt update
RUN apt install -y golang-go
RUN apt install -y git

RUN go version

RUN go build -o myapp

EXPOSE 8080

CMD ["./myapp"]

