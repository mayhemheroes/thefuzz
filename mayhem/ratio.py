#!/usr/bin/python3
import atheris
import sys

with atheris.instrument_imports():
    from thefuzz import fuzz
    from thefuzz import process

@atheris.instrument_func
def TestOneCompare(fdp):
    num = fdp.ConsumeIntInRange(0, 7)
    str1 = fdp.ConsumeString(32)
    str2 = fdp.ConsumeString(32)

    if num == 0:
        fuzz.ratio(str1, str2)
    elif num == 1:
        fuzz.partial_ratio(str1, str2)
    elif num == 2:
        fuzz.token_sort_ratio(str1, str2)
    elif num == 3:
        fuzz.token_set_ratio(str1, str2)
    elif num == 4:
        fuzz.UQRatio(str1, str2)
    elif num == 5:
        fuzz.QRatio(str1, str2)
    elif num == 6:
        fuzz.UWRatio(str1, str2)
    elif num == 7:
        fuzz.WRatio(str1, str2)

@atheris.instrument_func
def TestOneProcess(fdp):
    useLimit = fdp.ConsumeBool()
    str1 = fdp.ConsumeString(32)
    str2 = fdp.ConsumeString(32)
    str3 = fdp.ConsumeString(32)
    str4 = fdp.ConsumeString(32)
    str5 = fdp.ConsumeString(32)
    str_arr = [str1, str2, str3, str4]

    if useLimit:
        limit = fdp.ConsumeIntInRange(-10, 10)
        process.extract(str5, str_arr, limit = limit)
    else:
        process.extractOne(str5, str_arr)

@atheris.instrument_func
def TestOneInput(data):
    fdp = atheris.FuzzedDataProvider(data)

    isFuzz = fdp.ConsumeBool()

    if isFuzz:
        TestOneCompare(fdp)
    else:
        TestOneProcess(fdp)

def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()

if __name__ == "__main__":
    main()