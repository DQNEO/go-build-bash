hello:
	./go-build.sh -o hello

test: hello
	docker run --rm -v `pwd`:/mnt/ -w /mnt ubuntu ./$<

clean:
	rm -f ./hello /tmp/go-build-bash


