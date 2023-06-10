hello:
	./go-build.sh -o hello

test: hello
	docker run --rm -v `pwd`:/mnt/ -w /mnt ubuntu ./$<

test_on_linux: hello
	./$<

clean:
	rm -rf ./hello /tmp/go-build-bash


