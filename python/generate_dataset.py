import argparse
import random
import string
import numpy as np
import pandas as pd
from datetime import datetime, timedelta
from faker import Faker

fake = Faker()
Faker.seed(42)
random.seed(42)
np.random.seed(42)

CATEGORIES = [
    (1, "Fishing"), (2, "Camping & Hiking"), (3, "Cleats"), (4, "Water Sports"),
    (5, "Indoor/Outdoor Games"), (6, "Electronics"), (7, "Cardio Equipment"),
    (8, "Shop By Sport"), (9, "Golf Bags & Carts"), (10, "Kids' Golf Clubs"),
]

DEPARTMENTS = [
    (2, "Fitness"), (3, "Footwear"), (4, "Apparel"), (5, "Golf"),
    (6, "Outdoors"), (7, "Fan Shop"), (8, "Technology"),
]

MARKETS = ["Pacific Asia", "USCA", "LATAM", "Europe", "Africa"]

ORDER_REGIONS = [
    "Southeast Asia", "South Asia", "Oceania", "Eastern Asia", "West Asia",
    "West Africa", "Central Africa", "North Africa", "Western Europe",
    "Northern Europe", "Southern Europe", "Eastern Europe", "Caribbean",
    "South America", "Central America", "North America",
]

# intentionally inconsistent country spellings used as a *pool* -> dirty on purpose
COUNTRY_VARIANTS = {
    "United States": ["United States", "USA", "US", "u.s.a.", "United States ", "usa"],
    "Vietnam": ["Vietnam", "Viet Nam", "VN", "vietnam "],
    "Ireland": ["Ireland", "IE", "ireland", "Rep. of Ireland"],
    "Germany": ["Germany", "DE", "germany", "Deutschland"],
    "Mexico": ["Mexico", "MX", "méxico", "mexico "],
    "Brazil": ["Brazil", "BR", "brasil", "brazil"],
    "Australia": ["Australia", "AU", "australia "],
}

DELIVERY_STATUSES = [
    "Advance shipping", "Late delivery", "Shipping on time", "Shipping canceled",
    # dirty variants
    "late delivery", "LATE DELIVERY", "Shipping On Time ", "advance shipping",
]

ORDER_STATUSES = [
    "COMPLETE", "PENDING", "CLOSED", "PENDING_PAYMENT", "CANCELED",
    "PROCESSING", "SUSPECTED_FRAUD", "ON_HOLD", "PAYMENT_REVIEW",
    # dirty variants
    "complete", "Pending ", "cancelled", "Closed", "processing",
]

SHIPPING_MODES = ["Standard Class", "First Class", "Second Class", "Same Day",
                   "standard class", "FIRST CLASS", "Same day ", "2nd Class"]

CUSTOMER_SEGMENTS = ["Consumer", "Corporate", "Home Office", "consumer", "CORPORATE", "Home office "]

TYPES = ["DEBIT", "CASH", "PAYMENT", "TRANSFER", "debit", "Cash ", "TRANSFER "]

NULL_FLAVORS = [np.nan, "", "N/A", "n/a", "null", "NULL", "-", "??", " ", "None"]

JUNK_SNIPPETS = ["<br>", "&nbsp;", "\u200b", "  ", "\t", "###", "N/A - check later"]


def maybe_null(value, null_rate=0.06):
    """Randomly replace a value with one of several 'null flavors'."""
    if random.random() < null_rate:
        return random.choice(NULL_FLAVORS)
    return value


def dirty_case(text):
    """Randomly mangle case/whitespace of a string."""
    r = random.random()
    if r < 0.15:
        return text.upper()
    elif r < 0.30:
        return text.lower()
    elif r < 0.40:
        return f"  {text}  "
    elif r < 0.45:
        return text + random.choice(JUNK_SNIPPETS)
    return text


def dirty_country(country):
    variants = COUNTRY_VARIANTS.get(country)
    if variants:
        return random.choice(variants)
    return country


def dirty_money(value, currency_junk_rate=0.25):
    """Turn a clean float into a dirty string sometimes."""
    if random.random() < currency_junk_rate:
        fmt = random.choice([
            f"${value:,.2f}", f"{value:.2f} ", f" {value:.2f}",
            f"${value:.0f}", "N/A", str(value).replace(".", ","),
        ])
        return fmt
    return round(value, 2)


def dirty_bool(flag):
    """Represent a 0/1 risk flag inconsistently."""
    mapping_pool = {
        0: [0, "0", "No", "NO", "no", False, "N"],
        1: [1, "1", "Yes", "YES", "yes", True, "Y"],
    }
    return random.choice(mapping_pool[flag])


def dirty_date(dt, broken_rate=0.05, missing_rate=0.04):
    """Format a datetime inconsistently, sometimes break it entirely."""
    if random.random() < missing_rate:
        return random.choice(["", "NaT", "0000-00-00", np.nan])
    if random.random() < broken_rate:
        return random.choice([
            "31/13/2026 25:99", "not a date", "2026-02-30 10:00:00",
            str(dt.year) + "--" + str(dt.month), "####",
        ])
    fmt = random.choice([
        "%Y-%m-%d %H:%M:%S", "%m/%d/%Y %H:%M", "%d-%m-%Y", "%B %d, %Y",
        "%Y/%m/%d", "%m/%d/%Y",
    ])
    return dt.strftime(fmt)


def dirty_zip(zipcode):
    r = random.random()
    if r < 0.10:
        return ""
    elif r < 0.20:
        return f"{zipcode}-{random.randint(1000,9999)}"
    elif r < 0.28:
        return f"{zipcode}{random.choice(string.ascii_uppercase)}"
    elif r < 0.33:
        return str(float(zipcode))  # "90210.0" style mess
    return zipcode


def dirty_email(fname, lname, cid):
    r = random.random()
    base = f"{fname}.{lname}{cid}@example.com".lower()
    if r < 0.05:
        return "N/A"
    if r < 0.10:
        return base.replace("@", "[at]")
    if r < 0.13:
        return base.upper()
    if r < 0.16:
        return " " + base + " "
    return base


def messy_text_block(text, junk_rate=0.2):
    if random.random() < junk_rate:
        return text + " " + random.choice(JUNK_SNIPPETS)
    return text


# ---------------------------------------------------------------------------
# Main generator
# ---------------------------------------------------------------------------

def generate(n_rows: int, n_customers: int, n_products: int) -> pd.DataFrame:
    print(f"Generating base lookup pools: {n_customers} customers, {n_products} products...")

    # --- customer pool ---
    customers = []
    for cid in range(1, n_customers + 1):
        country_key = random.choice(list(COUNTRY_VARIANTS.keys()))
        customers.append({
            "Customer Id": cid,
            "Customer Fname": fake.first_name(),
            "Customer Lname": fake.last_name(),
            "Customer Password": "".join(random.choices(string.ascii_letters + string.digits, k=10)) if random.random() > 0.02 else "",
            "Customer Segment": random.choice(CUSTOMER_SEGMENTS),
            "Customer City": fake.city(),
            "Customer Country_key": country_key,
            "Customer State": fake.state_abbr(),
            "Customer Street": fake.street_address(),
            "Customer Zipcode": fake.postcode(),
        })
    cust_df = pd.DataFrame(customers)

    # --- product pool ---
    products = []
    for pid in range(1, n_products + 1):
        cat = random.choice(CATEGORIES)
        dept = random.choice(DEPARTMENTS)
        price = round(np.random.uniform(5, 2000), 2)
        products.append({
            "Product Card Id": pid,
            "Product Category Id": cat[0],
            "Category Id": cat[0],
            "Category Name": cat[1],
            "Department Id": dept[0],
            "Department Name": dept[1],
            "Product Name": fake.catch_phrase() + " " + random.choice(["Kit", "Pro", "Set", "Gear", "Combo"]),
            "Product Description": "",  # DataCo's real column is almost entirely blank -> keep that quirk
            "Product Image": f"http://images.example.com/products/{pid}.png",
            "Product Price": price,
            "Product Status": random.choice([0, 1, 0, 1, 1]),  # mostly 0 (active) like the real dataset
        })
    prod_df = pd.DataFrame(products)

    print(f"Generating {n_rows} order-item rows...")

    start_date = datetime(2024, 1, 1)
    end_date = datetime(2026, 7, 30)
    date_span_days = (end_date - start_date).days

    rows = []
    for i in range(n_rows):
        cust = cust_df.iloc[random.randrange(n_customers)]
        prod = prod_df.iloc[random.randrange(n_products)]

        order_offset = random.randint(0, date_span_days)
        order_dt = start_date + timedelta(days=order_offset, hours=random.randint(0, 23), minutes=random.randint(0, 59))

        days_scheduled = random.choice([1, 2, 3, 4, 5])
        days_real = max(0, days_scheduled + random.choice([-2, -1, -1, 0, 0, 0, 1, 1, 2, 3, 10]))  # occasional big delay outlier
        ship_dt = order_dt + timedelta(days=days_real)

        late_flag = 1 if days_real > days_scheduled else 0

        qty = random.choice([1, 1, 2, 2, 3, 4, 5, -1, 0])  # -1/0 are intentional bad values
        unit_price = prod["Product Price"]
        discount_rate = round(random.uniform(0, 0.4), 2)
        discount = round(unit_price * qty * discount_rate, 2) if qty > 0 else round(random.uniform(0, 50), 2)
        sales = round(unit_price * max(qty, 0), 2)
        order_item_total = round(sales - discount, 2)
        profit_ratio = round(random.uniform(-0.3, 0.5), 3)
        profit = round(order_item_total * profit_ratio, 2)

        order_region = random.choice(ORDER_REGIONS)
        market = random.choice(MARKETS)

        # occasionally corrupt lat/long (swapped, zero, or way out of range)
        lat = fake.latitude()
        lon = fake.longitude()
        if random.random() < 0.03:
            lat, lon = lon, lat  # swapped
        elif random.random() < 0.02:
            lat, lon = 0, 0

        row = {
            "Type": maybe_null(dirty_case(random.choice(TYPES))),
            "Days for shipping (real)": maybe_null(days_real),
            "Days for shipment (scheduled)": maybe_null(days_scheduled),
            "Benefit per order": maybe_null(dirty_money(profit)),
            "Sales per customer": maybe_null(dirty_money(round(sales * random.uniform(0.8, 1.2), 2))),
            "Delivery Status": maybe_null(random.choice(DELIVERY_STATUSES)),
            "Late_delivery_risk": dirty_bool(late_flag),
            "Category Id": prod["Category Id"],
            "Category Name": maybe_null(dirty_case(prod["Category Name"])),
            "Customer City": maybe_null(dirty_case(cust["Customer City"])),
            "Customer Country": maybe_null(dirty_country(cust["Customer Country_key"])),
            "Customer Email": dirty_email(cust["Customer Fname"], cust["Customer Lname"], cust["Customer Id"]),
            "Customer Fname": maybe_null(cust["Customer Fname"]),
            "Customer Id": cust["Customer Id"],
            "Customer Lname": maybe_null(cust["Customer Lname"]),
            "Customer Password": cust["Customer Password"],
            "Customer Segment": maybe_null(dirty_case(cust["Customer Segment"])),
            "Customer State": maybe_null(cust["Customer State"]),
            "Customer Street": messy_text_block(cust["Customer Street"]),
            "Customer Zipcode": dirty_zip(cust["Customer Zipcode"]),
            "Department Id": prod["Department Id"],
            "Department Name": maybe_null(dirty_case(prod["Department Name"])),
            "Latitude": lat,
            "Longitude": lon,
            "Market": maybe_null(dirty_case(market)),
            "Order City": maybe_null(dirty_case(fake.city())),
            "Order Country": maybe_null(dirty_country(random.choice(list(COUNTRY_VARIANTS.keys())))),
            "Order Customer Id": cust["Customer Id"],
            "order date (DateOrders)": dirty_date(order_dt),
            "Order Id": 100000 + (i // random.randint(1, 4)),  # some orders share id across items; some dup on purpose
            "Order Item Cardprod Id": prod["Product Card Id"],
            "Order Item Discount": maybe_null(dirty_money(discount)),
            "Order Item Discount Rate": maybe_null(discount_rate),
            "Order Item Id": i + 1 if random.random() > 0.002 else random.randint(1, n_rows),  # ~0.2% duplicate ids
            "Order Item Product Price": maybe_null(dirty_money(unit_price)),
            "Order Item Profit Ratio": maybe_null(profit_ratio),
            "Order Item Quantity": maybe_null(qty),
            "Sales": maybe_null(dirty_money(sales)),
            "Order Item Total": maybe_null(dirty_money(order_item_total)),
            "Order Profit Per Order": maybe_null(dirty_money(profit)),
            "Order Region": maybe_null(dirty_case(order_region)),
            "Order State": maybe_null(fake.state_abbr()),
            "Order Status": maybe_null(random.choice(ORDER_STATUSES)),
            "Order Zipcode": dirty_zip(fake.postcode()),
            "Product Card Id": prod["Product Card Id"],
            "Product Category Id": prod["Product Category Id"],
            "Product Description": prod["Product Description"],
            "Product Image": prod["Product Image"],
            "Product Name": maybe_null(dirty_case(prod["Product Name"])),
            "Product Price": maybe_null(dirty_money(prod["Product Price"])),
            "Product Status": prod["Product Status"],
            "shipping date (DateOrders)": dirty_date(ship_dt),
            "Shipping Mode": maybe_null(dirty_case(random.choice(SHIPPING_MODES))),
        }
        rows.append(row)

        if (i + 1) % 25000 == 0:
            print(f"  ...{i + 1:,} rows generated")

    df = pd.DataFrame(rows)

    # --- inject exact duplicate rows (a classic real-world dirty-data issue) ---
    n_dupes = int(n_rows * 0.015)
    dupe_rows = df.sample(n=n_dupes, random_state=1)
    df = pd.concat([df, dupe_rows], ignore_index=True)

    # shuffle so duplicates aren't obviously adjacent
    df = df.sample(frac=1, random_state=7).reset_index(drop=True)

    return df


def main():
    parser = argparse.ArgumentParser(description="Generate a dirty synthetic supply chain dataset.")
    parser.add_argument("--rows", type=int, default=220_000, help="Number of base order-item rows before duplicates are added")
    parser.add_argument("--customers", type=int, default=8_000, help="Number of unique customers to simulate")
    parser.add_argument("--products", type=int, default=500, help="Number of unique products to simulate")
    parser.add_argument("--out", type=str, default="dirty_supply_chain.csv", help="Output CSV path")
    args = parser.parse_args()

    df = generate(args.rows, args.customers, args.products)

    print(f"Final dataset shape (including injected duplicates): {df.shape}")
    df.to_csv(args.out, index=False)
    print(f"Saved to {args.out}")


if __name__ == "__main__":
    main()