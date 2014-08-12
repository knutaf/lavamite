int count = 0;
const int switchingPin = 13;

// for the SainSmart relay this uses, high voltage is "off"
const int POWER_OFF = LOW;
const int POWER_ON = HIGH;

int inByte = 0;         // incoming serial byte

//
// checks whether a given character matches any string in the set at the
// given position. returns the index of the first string that matches.
// assumes all strings are the same length. assumes the last element in the
// array of strings is NULL
//
int matchesAnyString(const char* const* strings, int posInString, char charAtPos)
{
    for (int i = 0; strings[i] != NULL; i++)
    {
        if (strings[i][posInString] == charAtPos)
        {
            return i;
        }
    }

    return -1;
}

//
// reads serial input until any of a set of strings is found. returns the
// index of the first string that matches. assumes all strings are the same
// length
//
// assumes there is at least one string in the array
//
int waitForString(const char* const* strings)
{
    int readPos = 0;
    int lastMatchedString = -1;

    //
    // all strings are assumed to be the same length. if our current read
    // position has a null terminator, then we have successfully matched a
    // string in the previous iteration of the loop. the index of this
    // previously matched string is in lastMatchedString
    //
    while (strings[0][readPos] != '\0')
    {
        //
        // every time there is serial data available, consume it all
        //
        while (Serial && Serial.available() > 0)
        {
            inByte = Serial.read();

            //
            // find if any string matches at our current read position. if
            // it does, advance our read position so we can then check the
            // next character
            //
            // if no string matched here, then reset our read position to the
            // beginning to try matching again from the start
            //
            lastMatchedString = matchesAnyString(strings, readPos, inByte);
            if (lastMatchedString != -1)
            {
                readPos++;
            }
            else
            {
                readPos = 0;
            }
        }

        delay(50);
    }

    return lastMatchedString;
}

void setup()
{
    pinMode(switchingPin, OUTPUT);
    digitalWrite(switchingPin, POWER_OFF);

    // start serial port at 9600 bps and wait for port to open:
    Serial.begin(9600);
    while (!Serial) {
        delay(50); // wait for serial port to connect. Needed for Leonardo only
    }
}

void loop()
{
    int foundString = -1;
    const char* strings[] = { "switch_1\0", "switch_0\0", NULL };

    foundString = waitForString(strings);
    switch (foundString)
    {
        case 0:
        digitalWrite(switchingPin, POWER_ON);
        count++;
        Serial.print("count: ");
        Serial.print(count);
        Serial.print("\n");
        break;

        case 1:
        digitalWrite(switchingPin, POWER_OFF);
        count++;
        Serial.print("count: ");
        Serial.print(count);
        Serial.print("\n");
        break;
    }
}
