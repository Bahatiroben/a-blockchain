build: 
	go build -o .bin/a-blockchain

run: build
	./.bin/a-blockchain