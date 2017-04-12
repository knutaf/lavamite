# LavaMite
## A Twitter bot that captures lava lamps in the act of forming.

[LavaMite](https://twitter.com/lava_mite) is comprised of four components:
* a lava lamp, of course
* an Arduino board that controls a relay to turn the power to the lamp on and off based on instructions over the serial input line
* a web cam to take pictures of the lava lamp when instructed to
* a program that schedules turning the lamp on and off, takes the picture of the lamp, and uploads it to [Twitter](https://twitter.com/lava_mite).

# Installation
(only works on Windows currently)

1. Make sure a webcam is connected to your Windows PC
1. Run `takephoto.exe -enum`. If you have more than one webcam connected to this computer, make note of which device ID your webcam is
1. In `powerswitch.ino`, adjust `switchingPin` according to which pin you want to use to control the power switch. If your relay activates with high voltage, you may have to swap the values of `POWER_OFF` and `POWER_ON`.
1. Compile and deploy `powerswitch.ino` to your Arduino board.
1. Make note of which COM port the Arduino board is connected to
1. Once you've wired up your Arduino to the power switch, you can test it manually by using the Arduino serial monitor with 9600 baud and sending the string `switch_1` or `switch_0`.
1. Rename `lavamite_config_dry_SAMPLE.json` as `lavamite_config.json`, and fill in the authentication values for your Twitter app.
1. Finally, run `lavamite.exe -live -com COM3 -cam 1`, substituting the camera device ID and COM port from above. If you only have one camera device, the `-cam` parameter can be omitted.

That's it! The program should be running. To exit it, type `quit`, and it should save its progress and pick up where you left off next time.

! More Information
I wrote [a blog introducing LavaMite](https://barncover.blogspot.com/2014/05/lavamite-it-out-now.html), and [some more details about its development](https://barncover.blogspot.com/2014/06/developing-lavamite.html).
