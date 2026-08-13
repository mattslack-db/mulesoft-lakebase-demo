INSERT INTO demo.customers (name, email, tier) VALUES
    ('Ada Lovelace',   'ada@example.com',   'gold'),
    ('Alan Turing',    'alan@example.com',  'standard'),
    ('Grace Hopper',   'grace@example.com', 'gold')
ON CONFLICT (email) DO NOTHING;
