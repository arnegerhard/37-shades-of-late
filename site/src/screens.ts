// Pictures of the app's screens, for the stats page's journey: what each screen Journey names looks like.
// Taken in the simulator (images/screens, 300 points wide); take them again when a screen changes much.

import cities from "../images/screens/cities.jpg";
import guide from "../images/screens/guide.jpg";
import home from "../images/screens/home.jpg";
import livemap from "../images/screens/livemap.jpg";
import pickerList from "../images/screens/picker.list.jpg";
import pickerMap from "../images/screens/picker.map.jpg";
import pickerStops from "../images/screens/picker.stops.jpg";
import share from "../images/screens/share.jpg";

export const SCREENS: Record<string, ArrayBuffer> = {
  home, livemap, "picker.map": pickerMap, "picker.list": pickerList, "picker.stops": pickerStops, share, cities, guide,
};
