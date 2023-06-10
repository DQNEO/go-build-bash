hello:
	./go-build.sh -o hello

# test on a non-linux host machine
test: hello
	docker run --rm -v `pwd`:/mnt/ -w /mnt ubuntu ./$<

# test on a linux host machine
test-on-linux: hello
	./$<

clean:
	rm -rf ./hello /tmp/go-build-bash


