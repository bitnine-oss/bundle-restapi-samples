-- Now we've got some data, let's start to explore the dataset.

-- ### Dataset
-- image::http://dev.assets.neo4j.com.s3.amazonaws.com/wp-content/uploads/Northwind_diagram.jpg[]
-- The Northwind Graph provides us with a rich dataset, but primarily we're interested in Customers and their Orders.   In a Graph, the data is modelled like so:
-- image::https://raw.githubusercontent.com/adam-cowley/northwind-neo4j/master/product-model.png[]

-- ### Popular Products
-- To find the most popular products in the dataset, we can follow the path from `:Customer` to `:Product`

match (c:customer)-[:PURCHASED]->(o:"order")-[:ORDERS]->(p:product) 
return c.companyName, p.productName, count(o) as orders
order by orders desc
limit 5;


-- ### Content Based Recommendations
-- The simplest recommendation we can make for a Customer is a content based recommendation.  Based on their previous purchases, can we recommend them anything that they haven't already bought?  For every product our customer has purchased, let's see what other customers have also purchased.  Each `:Product` is related to a `:Category`  so we can use this to further narrow down the list of products to recommend.

-- // table

match (c:customer)-[:PURCHASED]->(o:"order")-[:ORDERS]->(p:product)
<-[:orders]-(o2:"order")-[:orders]->(p2:product)-[:PART_OF]->(:category)<-[:PART_OF]-(p)
WHERE c.ID = 'ANTON' and NOT EXISTS( (c)-[:PURCHASED]->(:"order")-[:ORDERS]->(p2) )
return c.companyName, p.productName as has_purchased, p2.productName as has_also_purchased, count(DISTINCT o2) as occurrences
order by occurrences desc
limit 5;


-- ### Collaborative Filtering
-- Collaborative Filtering is a technique used by recommendation engines to recommend content based on the feedback from other Customers.  To do this, we can use the k-NN (k-nearest neighbors) Algorithm.  k-N works by grouping items into classifications based on their similarity to eachother.  In our case, this could be ratings between two Customers for a Product.  To give a real world example, this is how sites like Netflix make recommendations based on the ratings given to shows you've already watched.

-- The first thing we need to do to make this model work is create some "ratings relationships".  For now, let's create a score somewhere between 0 and 1 for each product based on the number of times a customer has purchased a product.

create elabel if not exists RATED;

MATCH (c:customer)-[:PURCHASED]->(o:"order")-[:ORDERS]->(p:product)
WITH c, count(p) as total
MATCH (c)-[:PURCHASED]->(o:"order")-[:ORDERS]->(p:product)
WITH c, total, p, count(o) as orders, round(count(o)*1.0/total,3) as rating
MERGE (c)-[rated:RATED {total_count: total, order_count: orders, rating: rating}]->(p)
;

MATCH path = (c:customer)-[r:RATED]->(p:product)
RETURN c.companyName, r.total_count, p.productName, r.order_count, r.rating, path
limit 100;

-- Now our model should look something like this:
-- https://raw.githubusercontent.com/adam-cowley/northwind-neo4j/master/ratings.png

MATCH (me:Customer)-[r:RATED]->(p:Product)
WHERE me.customerID = 'ANTON' RETURN p.productName, r.rating limit 10

-- Now we can use these ratings to compare the preferences of two Customers.

-- // See Customer's Similar Ratings to Others
match (c1:customer {customerID:'ANTON'})-[r1:RATED]->(p:product)<-[r2:RATED]-(c2:customer)
return c1.customerID, c2.customerID, p.productName, r1.rating, r2.rating, 
            abs(r1.rating::float-r2.rating::float) as difference
order by difference ASC
limit 15;


-- Now, we can create a similarity score between two Customers using Cosine Similarity (Hat tip to Nicole White for the original Cypher query...)

match (c:customer)-[r:rated]->(p:product)
with c, count(p) as p_length , sqrt( sum( r.rating::float^2 ) ) as r_length
set c.p_length = to_json(p_length::int), c.r_length = to_json(r_length::float) 
;


create elabel if not exists SIMILARITY;

-- // test
-- MATCH (c1:customer)-[r1:RATED]->(p:product)<-[r2:RATED]-(c2:customer)
-- WITH c1, c2, SUM(r1.rating::float*r2.rating::float) as dot_product, count(p) as dot_length,
-- c1.p_length as c1_plength, c2.p_length as c2_plength, c1.r_length as c1_rlength, c2.r_length as c2_rlength,
-- SUM(r1.rating::float*r2.rating::float) / ( c1.r_length::float * c2.r_length::float ) as similarity
-- return c1, c2, dot_product, dot_length, similarity
-- limit 10;

MATCH (c1:customer)-[r1:RATED]->(p:product)<-[r2:RATED]-(c2:customer)
WITH c1, c2, SUM(r1.rating::float*r2.rating::float) as dot_product, count(p) as dot_length,
c1.p_length as c1_plength, c2.p_length as c2_plength, c1.r_length as c1_rlength, c2.r_length as c2_rlength,
SUM(r1.rating::float*r2.rating::float) / ( c1.r_length::float * c2.r_length::float ) as similarity
merge (c1)-[:SIMILARITY { dot_product: to_json(dot_product::float), dot_length: to_json(dot_length::int), similarity: to_json(similarity::float) }]-(c2)
;

-- // test
match (c1:customer)-[s:SIMILARITY]->(c2:customer)
return c1, s, c2
order by c1.id, s.similarity desc
limit 10;

-- 최상위 유사도 2명 나옴 
-- // result: c1.ID='ANTON' and s.dot_length::int > 2 and s.similarity::float > 0.4
match (c1:customer)-[s:SIMILARITY]->(c2:customer),
path1=(c1)-[]->(:"order")-[]-(:product)-[]-(:category), path2=(c2)-[]->(:"order")-[]-(:product)-[]-(:category)
where c1.ID='ANTON' and s.dot_length::int > 2 and s.similarity::float > 0.4
return path1, path2, s
order by s.similarity desc
;



-- Great, let's now make a recommendation based on these similarity scores.

-- SAMPLE: 고객에 상품 하나 대입
MATCH path=(me:customer)-[s:SIMILARITY]->(c:customer)-[r:RATED]->(p:product)
where me.id='ANTON' and p.name='Gorgonzola Telino' and not exists( (me)-[:RATED]->(p) )
with path, s.similarity as similarity, c.id as neighbor_name
return path, similarity, neighbor_name
order by similarity desc
limit 5;


MATCH path=(me:customer)-[s:SIMILARITY]->(c:customer)-[r:RATED]->(p:product)
where me.id='ANTON' and not exists( (me)-[:RATED]->(p) )
with me.id as cust_id, p.name as prod_name, avg(s.similarity::float) as sim_avg, count(r) as rating_cnt, sum(r.rating::float) as rating_sum
where sim_avg > 0.2 and rating_cnt > 5
return cust_id, prod_name, sim_avg, rating_cnt, rating_sum
order by rating_sum desc
limit 50;

MATCH (me:customer)-[s:SIMILARITY]->(c:customer)-[r:RATED]->(p:product)
where me.id='ANTON' and not exists( (me)-[:RATED]->(p) )
with me, p, avg(s.similarity::float) as sim_avg, count(r) as rating_cnt, sum(r.rating::float) as rating_sum
merge (me)-[:recommend {similarity_avg: to_json(sim_avg::float), rating_cnt: to_json(rating_cnt::int), rating_sum: to_json(rating_sum::float) }]->(p)
;

-- 참고 jsonb_agg( to_json(c.id::text) )
-- ** 유사 함수로 string_agg( c.id::text, '|' )도 있음 => 'A | B | C | ..'

-- 아직 미완료 쿼리
WITH 1 as neighbours
MATCH (me:Customer)-[:SIMILARITY]->(c:Customer)-[r:RATED]->(p:Product)
WHERE me.customerID = 'ANTON' and NOT ( (me)-[:RATED|PRODUCT|ORDER*1..2]->(p:Product) )
WITH p, COLLECT(r.rating)[0..neighbours] as ratings, collect(c.companyName)[0..neighbours] as customers
WITH p, customers, REDUCE(s=0,i in ratings | s+i) / LENGTH(ratings)  as recommendation
ORDER BY recommendation DESC
RETURN p.productName, customers, recommendation LIMIT 10

