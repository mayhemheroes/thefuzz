FROM fuzzers/atheris:2.0.7-python3.9

COPY . /thefuzz

# Build Project
WORKDIR /thefuzz
RUN pip install python-Levenshtein
RUN pip install .

# Change Permissions
RUN chmod +x /thefuzz/mayhem/ratio.py