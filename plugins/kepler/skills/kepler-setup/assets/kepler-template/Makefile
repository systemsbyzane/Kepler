.PHONY: test validate validate-deliverables doctor

test:
	ruby -Ilib tests/kepler_test.rb

doctor:
	bin/kepler doctor --json

validate: test
	ruby -c bin/kepler
	@for file in lib/kepler/*.rb; do ruby -c "$$file" >/dev/null || exit 1; done
	@ruby -e 'require "json"; require "yaml"; ARGV.each { |p| File.extname(p) == ".json" ? JSON.parse(File.read(p)) : YAML.safe_load(File.read(p), aliases: false) }' $$(find . \
		-path ./.git -prune -o \
		-path ./.kepler-local -prune -o \
		-path ./charts -prune -o \
		-path ./compliance -prune -o \
		-path ./development -prune -o \
		-path ./environments -prune -o \
		-path ./handoffs -prune -o \
		-path ./patching -prune -o \
		-path ./research -prune -o \
		-path ./hub/cache -prune -o \
		-path ./hub/reports -prune -o \
		-path ./hub/state -prune -o \
		-path ./hub/tmp -prune -o \
		-type f \( -name '*.json' -o -name '*.yaml' -o -name '*.yml' \) -print)
	@echo "Kepler validation passed."

validate-deliverables:
	@found=0; \
	for directory in compliance/*/deliverables; do \
		test -d "$$directory" || continue; \
		found=1; \
		python3 scripts/validate-deliverable.py "$$directory" --json || exit 1; \
	done; \
	test $$found -eq 1 || echo "No program deliverables directories found."
