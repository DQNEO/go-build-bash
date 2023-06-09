hello:
	./go-build.sh

test: hello
	docker run --rm -v `pwd`:/mnt/ -w /mnt ubuntu ./$<

clean:
	rm -f ./hello /tmp/go-build-bash


